// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VLMKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v1),
        .tvOS(.v17),
    ],
    products: [
        .library(name: "VLMKit", targets: ["VLMKit"]),
        .executable(name: "vlmkit-cli", targets: ["vlmkit-cli"]),
    ],
    dependencies: [
        // VLM inference backend. The MLX VLM/LLM libraries moved out of
        // mlx-swift-examples into this dedicated package as of the 3.x line.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3"),
        // mlx-swift is already resolved transitively via mlx-swift-lm; declared
        // directly so the backend can tune MLX GPU memory (Memory.cacheLimit /
        // clearCache). Same constraint mlx-swift-lm uses, so no version conflict.
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.3")),
        // mlx-swift-lm 3.31.3's HuggingFace loader macros expand to code that
        // references the `HuggingFace` (HubClient) and `Tokenizers` modules, so a
        // consumer must supply them directly. Versions match mlx-swift-lm's own
        // IntegrationTesting project.
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "VLMKit",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ]
        ),
        .executableTarget(
            name: "vlmkit-cli",
            dependencies: ["VLMKit"]
        ),
        .testTarget(
            name: "VLMKitTests",
            dependencies: ["VLMKit"]
        ),
    ],
    // Build in Swift 5 language mode: VLMKit composes Sendable inputs and never
    // shares mutable VLM state across tasks, but full Swift 6 strict-concurrency
    // checking of the MLX boundary types is deferred.
    swiftLanguageModes: [.v5]
)
