import Foundation

/// Runs `VLMTask`s against a backend: composes the prompt, generates, extracts
/// JSON from the response, decodes it, and retries with a correction note if the
/// output is unparseable. This is the atom every recipe builds on — fan-out is
/// just calling `run` many times and aggregating.
public struct VLMRunner: Sendable {
    public let backend: any VLMBackend
    /// Extra attempts when output can't be parsed (total tries = `retries` + 1).
    public var retries: Int

    public init(backend: any VLMBackend, retries: Int = 1) {
        self.backend = backend
        self.retries = retries
    }

    /// Run a typed task on the given images (one VLM call), decoded to `Output`.
    public func run<Output: Decodable & Sendable>(
        _ task: VLMTask<Output>,
        images: [VLMImage]
    ) async throws -> Output {
        var correction = ""
        var lastText = ""
        for _ in 0...retries {
            let result = try await backend.generate(
                prompt: correction + task.composedPrompt(),
                system: task.system,
                images: images,
                options: task.options
            )
            lastText = result.text
            if let data = JSONExtraction.data(from: result.text),
               let decoded = try? JSONDecoder().decode(Output.self, from: data) {
                return decoded
            }
            correction = "Your previous response could not be parsed as the requested JSON. Output ONLY the JSON value. "
        }
        throw VLMKitError.decodingFailed(raw: lastText)
    }

    /// Run a free-form text task (no decoding) — useful for description/smoke tests.
    public func runText(
        instruction: String,
        system: String? = nil,
        images: [VLMImage] = [],
        options: GenerationOptions = .init()
    ) async throws -> GenerationResult {
        try await backend.generate(prompt: instruction, system: system, images: images, options: options)
    }
}
