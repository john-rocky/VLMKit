/// Model-specific configuration. Decouples VLMKit's public API from any single
/// backend's model registry — `identifier` is the Hugging Face repo id passed
/// to whichever backend loads it.
public struct ModelProfile: Sendable {
    /// Hugging Face repo id of an MLX-format model.
    public let identifier: String
    public let displayName: String
    public let capabilities: VLMCapabilities
    /// Approximate resident memory, GB. Informational (model-selection hints).
    public let approxMemoryGB: Double

    public init(
        identifier: String,
        displayName: String,
        capabilities: VLMCapabilities,
        approxMemoryGB: Double
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.capabilities = capabilities
        self.approxMemoryGB = approxMemoryGB
    }
}

public extension ModelProfile {
    /// Default model: best accuracy/size tradeoff for broad device support.
    static let qwen3VL4B = ModelProfile(
        identifier: "lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit",
        displayName: "Qwen3-VL 4B Instruct (4-bit)",
        capabilities: [.imageInput, .multipleImages, .videoInput, .streaming],
        approxMemoryGB: 3.0
    )

    /// Larger Qwen3-VL for higher-memory devices (M-series Macs, 16GB+ iPad).
    // NOTE: verify this repo id exists on Hugging Face for your target;
    // swap in another mlx-community Qwen3-VL-8B 4-bit repo if it 404s.
    static let qwen3VL8B = ModelProfile(
        identifier: "mlx-community/Qwen3-VL-8B-Instruct-4bit",
        displayName: "Qwen3-VL 8B Instruct (4-bit)",
        capabilities: [.imageInput, .multipleImages, .videoInput, .streaming],
        approxMemoryGB: 6.0
    )

    /// Smallest preset — fast, runs on 8GB iPhones. Lower accuracy.
    static let smolVLM2 = ModelProfile(
        identifier: "HuggingFaceTB/SmolVLM2-500M-Video-Instruct-mlx",
        displayName: "SmolVLM2 500M",
        capabilities: [.imageInput, .videoInput, .streaming],
        approxMemoryGB: 1.0
    )

    /// All built-in presets, smallest model first.
    static let presets: [ModelProfile] = [smolVLM2, qwen3VL4B, qwen3VL8B]
}
