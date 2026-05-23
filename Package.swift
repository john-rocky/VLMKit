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
    ],
    targets: [
        .target(
            name: "VLMKit",
            dependencies: [
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
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
