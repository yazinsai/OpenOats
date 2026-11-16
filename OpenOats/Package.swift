// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OpenOats",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "OatsCore", targets: ["OatsCore"]),
        .library(name: "OatsOnDevice", targets: ["OatsOnDevice"]),
        .executable(name: "oats", targets: ["oats"]),
        .executable(name: "OpenOats", targets: ["OpenOats"]),
    ],
    dependencies: [
        // FluidAudio breaks source in patch releases; pin exactly.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.13.5"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", .upToNextMinor(from: "0.17.0")),
    ],
    targets: [
        .target(name: "OatsCore"),
        .target(
            name: "OatsOnDevice",
            dependencies: [
                "OatsCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        .executableTarget(name: "oats", dependencies: ["OatsCore", "OatsOnDevice"]),
        .executableTarget(
            name: "OpenOats",
            dependencies: ["OatsCore"],
            exclude: ["Info.plist", "OpenOats.entitlements", "Assets"]
        ),
        .testTarget(name: "OatsCoreTests", dependencies: ["OatsCore"]),
        .testTarget(name: "OnDeviceGoldenTests", dependencies: ["OatsCore", "OatsOnDevice"]),
    ]
)
