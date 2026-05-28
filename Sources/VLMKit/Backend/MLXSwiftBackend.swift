import CoreGraphics
import CoreImage
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers

/// `VLMBackend` backed by `mlx-swift-lm` (GPU inference on Apple Silicon).
///
/// An `actor` so the underlying `ModelContainer` (single GPU model) is accessed
/// serially. Fan-out therefore runs as N sequential VLM calls through one model
/// rather than parallel GPU batches — which is what the hardware supports.
public actor MLXSwiftBackend: VLMBackend {
    public nonisolated let profile: ModelProfile
    private var container: ModelContainer?

    public init(profile: ModelProfile = .qwen3VL4B) {
        self.profile = profile
    }

    public func load(onProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await load(from: nil, onProgress: onProgress)
    }

    /// Load from a model directory already on disk — e.g. one sideloaded onto the
    /// device via USB — skipping the Hugging Face download. Pass `nil` to download
    /// `profile.identifier` from the Hub. A `.directory` configuration makes
    /// mlx-swift-lm's loader read the local files and never touch the network.
    public func load(
        from localModel: URL?,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard container == nil else { return }
        // MLX's buffer cache defaults to the (multi-GB) memory limit, so freed
        // buffers pile up across the sequential fan-out calls until iOS jetsam-kills
        // the app. Cap it to keep peak memory bounded on-device.
        MLX.Memory.cacheLimit = 256 * 1024 * 1024
        let configuration = localModel.map { ModelConfiguration(directory: $0) }
            ?? ModelConfiguration(id: profile.identifier)
        container = try await VLMModelFactory.shared.loadContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: configuration,
            progressHandler: { progress in onProgress?(progress.fractionCompleted) }
        )
    }

    private func loaded() throws -> ModelContainer {
        guard let container else { throw VLMKitError.modelNotLoaded }
        return container
    }

    public func generate(
        prompt: String,
        system: String?,
        images: [VLMImage],
        options: GenerationOptions
    ) async throws -> GenerationResult {
        let container = try loaded()
        let result = try await container.perform { [prompt, system, images, options] context in
            let input = try await context.processor.prepare(
                input: Self.makeUserInput(prompt: prompt, system: system, images: images)
            )
            var text = ""
            var stats: GenerationStats?
            for await item in try MLXLMCommon.generate(
                input: input, parameters: Self.parameters(options), context: context
            ) {
                switch item {
                case .chunk(let chunk):
                    text += chunk
                case .info(let info):
                    // NOTE: GenerateCompletionInfo field names per mlx-swift-lm 3.x.
                    stats = GenerationStats(
                        promptTokens: info.promptTokenCount,
                        generatedTokens: info.generationTokenCount,
                        tokensPerSecond: info.tokensPerSecond,
                        totalSeconds: info.promptTime + info.generateTime
                    )
                default:
                    break
                }
            }
            return GenerationResult(text: text, stats: stats)
        }
        // Release buffers cached during this generation so they don't accumulate
        // across the sequential fan-out calls.
        MLX.Memory.clearCache()
        return result
    }

    public nonisolated func stream(
        prompt: String,
        system: String?,
        images: [VLMImage],
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let container = try await self.loaded()
                    try await container.perform { [prompt, system, images, options] context in
                        let input = try await context.processor.prepare(
                            input: Self.makeUserInput(prompt: prompt, system: system, images: images)
                        )
                        for await item in try MLXLMCommon.generate(
                            input: input, parameters: Self.parameters(options), context: context
                        ) {
                            if case .chunk(let chunk) = item { continuation.yield(chunk) }
                        }
                    }
                    MLX.Memory.clearCache()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Input building

    private static func makeUserInput(prompt: String, system: String?, images: [VLMImage]) -> UserInput {
        var messages: [Chat.Message] = []
        if let system { messages.append(.system(system)) }
        messages.append(.user(prompt, images: images.map { .ciImage(Self.downscaled($0.ciImage)) }))
        return UserInput(chat: messages)
    }

    /// Cap an input image to a total-pixel budget (preserving aspect ratio) before
    /// inference. Qwen3-VL's processor leaves `max_pixels` unset (allowing ~16 MP),
    /// so a full-resolution camera image produces a huge vision-token sequence — a
    /// 12 MP photo peaked at ~87 GB here. Bounding pixels bounds the vision-token
    /// count and therefore peak memory. Lower it if a tighter device still OOMs.
    private static let maxInputPixels: CGFloat = 786_432  // 0.79 MP (≈ 1024×768) — ~6.3 GB peak on-device

    private static func downscaled(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let pixels = extent.width * extent.height
        guard pixels > maxInputPixels else { return image }
        let scale = (maxInputPixels / pixels).squareRoot()
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    private static func parameters(_ options: GenerationOptions) -> GenerateParameters {
        GenerateParameters(
            maxTokens: options.maxTokens,
            temperature: options.temperature,
            topP: options.topP
        )
    }
}
