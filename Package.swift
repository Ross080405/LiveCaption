// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LiveCaption",
    platforms: [.macOS(.v14)],
    dependencies: [
        // WhisperKit（Argmax 开源，Whisper 在 Apple 芯片上本地运行）。锁定版本，避免更新后接口变化。
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
    ],
    targets: [
        .executableTarget(
            name: "LiveCaption",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources"
        ),
    ]
)
