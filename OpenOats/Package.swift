// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OpenOats",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "OatsCore", targets: ["OatsCore"]),
        .executable(name: "oats", targets: ["oats"]),
        .executable(name: "OpenOats", targets: ["OpenOats"]),
    ],
    targets: [
        .target(name: "OatsCore"),
        .executableTarget(name: "oats", dependencies: ["OatsCore"]),
        .executableTarget(
            name: "OpenOats",
            dependencies: ["OatsCore"],
            exclude: ["Info.plist", "OpenOats.entitlements", "Assets"]
        ),
        .testTarget(name: "OatsCoreTests", dependencies: ["OatsCore"]),
    ]
)
