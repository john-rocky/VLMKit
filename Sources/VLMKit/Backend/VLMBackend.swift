/// Sampling parameters for a single generation.
public struct GenerationOptions: Sendable {
    public var maxTokens: Int
    public var temperature: Float
    public var topP: Float

    /// Defaults favour deterministic extraction (low temperature) rather than
    /// chat-style creativity — recipes parse the output as structured data.
    public init(maxTokens: Int = 512, temperature: Float = 0.2, topP: Float = 1.0) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
    }
}

/// Throughput numbers reported by the backend for a generation.
public struct GenerationStats: Sendable {
    public let promptTokens: Int
    public let generatedTokens: Int
    public let tokensPerSecond: Double
    public let totalSeconds: Double

    public init(promptTokens: Int, generatedTokens: Int, tokensPerSecond: Double, totalSeconds: Double) {
        self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens
        self.tokensPerSecond = tokensPerSecond
        self.totalSeconds = totalSeconds
    }
}

public struct GenerationResult: Sendable {
    public let text: String
    public let stats: GenerationStats?

    public init(text: String, stats: GenerationStats? = nil) {
        self.text = text
        self.stats = stats
    }
}

/// Raw inference protocol. The single seam between VLMKit's orchestration
/// (extractors, runner, recipes) and a concrete inference engine. Phase 1 ships
/// one conformer, `MLXSwiftBackend`; CoreML / Foundation / remote backends slot
/// in here later without touching the layers above.
public protocol VLMBackend: Sendable {
    var profile: ModelProfile { get }

    /// Download (if needed) and load the model into memory.
    func load(onProgress: (@Sendable (Double) -> Void)?) async throws

    /// Drop the in-memory model so a co-resident on-device pipeline (e.g. an
    /// on-device diffusion model in the Background Studio) can use the GPU/ANE
    /// and RAM the VLM was occupying. The next `load*` call cold-loads the
    /// weights again. The default is a no-op so backends with cheap models or
    /// no jetsam pressure don't have to implement it.
    func unload() async

    /// Run one generation and return the full text once complete.
    func generate(
        prompt: String,
        system: String?,
        images: [VLMImage],
        options: GenerationOptions
    ) async throws -> GenerationResult

    /// Run one generation, yielding text chunks as they are produced.
    func stream(
        prompt: String,
        system: String?,
        images: [VLMImage],
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, Error>
}

public extension VLMBackend {
    func load() async throws {
        try await load(onProgress: nil)
    }

    func unload() async {}

    func generate(
        prompt: String,
        images: [VLMImage] = [],
        options: GenerationOptions = .init()
    ) async throws -> GenerationResult {
        try await generate(prompt: prompt, system: nil, images: images, options: options)
    }

    func stream(
        prompt: String,
        images: [VLMImage] = [],
        options: GenerationOptions = .init()
    ) -> AsyncThrowingStream<String, Error> {
        stream(prompt: prompt, system: nil, images: images, options: options)
    }
}
