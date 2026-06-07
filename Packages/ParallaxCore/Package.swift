// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ParallaxCore",
    platforms: [
        .iOS(.v26),
        .tvOS(.v26),
        // macOS baseline exists only so `swift test` works on the dev host
        // and on macos-15 CI runners. macOS is NOT a shipping target —
        // Pinned high (.v15) to minimize the iOS/macOS API-availability gap.
        .macOS(.v15),
    ],
    products: [
        .library(name: "ParallaxCore", targets: ["ParallaxCore"]),
    ],
    targets: [
        .target(
            name: "ParallaxCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ParallaxCoreTests",
            dependencies: ["ParallaxCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
