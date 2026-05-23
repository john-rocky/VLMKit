import CoreImage
import Foundation
import MLXHuggingFace
import MLXLMCommon
import MLXVLM

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
        guard container == nil else { return }
        container = try await VLMModelFactory.shared.loadContainer(
            from: HubClient.default,
            using: TokenizersLoader(),
            configuration: ModelConfiguration(id: profile.identifier),
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
        return try await container.perform { [prompt, system, images, options] context in
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
        messages.append(.user(prompt, images: images.map { .ciImage($0.ciImage) }))
        return UserInput(chat: messages)
    }

    private static func parameters(_ options: GenerationOptions) -> GenerateParameters {
        GenerateParameters(
            maxTokens: options.maxTokens,
            temperature: options.temperature,
            topP: options.topP
        )
    }
}
