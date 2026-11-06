// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TypeLeastMLXWorker",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", exact: "0.1.8"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.33.0")
    ],
    targets: [
        .executableTarget(
            name: "mlx-asr",
            dependencies: [
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLX", package: "mlx-swift")
            ]
        ),
        .testTarget(name: "MLXWorkerTests", dependencies: ["mlx-asr"])
    ]
)
