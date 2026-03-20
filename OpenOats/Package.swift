// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OpenOats",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "OpenOats",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/OpenOats",
            exclude: ["Info.plist", "OpenOats.entitlements", "Assets"]
        ),
        .testTarget(
            name: "OpenOatsTests",
            dependencies: ["OpenOats"],
            path: "Tests/OpenOatsTests"
        ),
    ]
)
