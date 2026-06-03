// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "DeepSeekStats",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "DeepSeekStats",
            resources: []
        ),
    ],
    swiftLanguageModes: [.v6]
)
