// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "DeepSeekStats",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.3.2"),
    ],
    targets: [
        .executableTarget(
            name: "DeepSeekStats",
            resources: []
        ),
        .testTarget(
            name: "DeepSeekStatsTests",
            dependencies: [
                "DeepSeekStats",
                .product(name: "Testing", package: "swift-testing"),
            ],
            linkerSettings: [
                // Command Line Tools installs Swift Testing's interop library here.
                .unsafeFlags([
                    "-L", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ]),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
