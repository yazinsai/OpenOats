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
        .executable(
            name: "Benchmark",
            targets: ["Benchmark"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.5"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
        // Fork with relaxed swift-transformers constraint (from: "1.1.6" instead of upToNextMinor)
        // to allow coexistence with FluidAudio 0.12.5 which requires swift-transformers >= 1.2.0.
        // TODO: Switch back to argmaxinc/WhisperKit once upstream relaxes the constraint.
        .package(url: "https://github.com/yazins-ai/WhisperKit.git", branch: "fix/swift-transformers-compat"),
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
        .executableTarget(
            name: "Benchmark",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/Benchmark"
        ),
        .testTarget(
            name: "OpenOatsTests",
            dependencies: ["OpenOatsKit"],
            path: "Tests/OpenOatsTests"
        ),
    ]
)
