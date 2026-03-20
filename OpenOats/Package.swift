// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OpenOats",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "OpenOatsKit",
            targets: ["OpenOatsKit"]
        ),
        .executable(
            name: "OpenOats",
            targets: ["OpenOatsAppExecutable"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "OpenOatsKit",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
            ],
            path: "Sources/OpenOats",
            exclude: ["Info.plist", "OpenOats.entitlements", "Assets", "Resources"]
        ),
        .executableTarget(
            name: "OpenOatsAppExecutable",
            dependencies: ["OpenOatsKit"],
            path: "Sources/OpenOatsApp"
        ),
        .testTarget(
            name: "OpenOatsTests",
            dependencies: ["OpenOatsKit"],
            path: "Tests/OpenOatsTests"
        ),
    ]
)
