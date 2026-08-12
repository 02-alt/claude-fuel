// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeFuel",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeFuel",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/ClaudeFuel",
            resources: [
                .copy("Resources/pcb.png"),
                .copy("Resources/ps2_startup.m4a"),
                .copy("Resources/xbox_startup.m4a"),
                .copy("Resources/shield_recharge.mp3"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
