// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Hearsay",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Hearsay", targets: ["Hearsay"]),
        // APFS is case-insensitive: a `hearsay` binary would overwrite `Hearsay` in .build. The install
        // script copies `hearsay-cli` to ~/.local/bin/hearsay.
        .executable(name: "hearsay-cli", targets: ["HearsayCLI"]),
        .library(name: "HearsayCore", targets: ["HearsayCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.7", traits: []),  // no traits: skips the unused NemoTextProcessing binary
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
        // Self-update for the Developer ID build; the App Store build strips it (scripts/build-app.sh --mas).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(
            name: "HearsayCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .target(name: "CrashSupport", linkerSettings: [.linkedFramework("Foundation")]),
        .executableTarget(
            name: "Hearsay",
            dependencies: ["HearsayCore", "CrashSupport", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .executableTarget(
            name: "HearsayCLI",
            dependencies: [
                "HearsayCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "HearsayCoreTests",
            dependencies: ["HearsayCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
