// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ParallaxPlayback",
    platforms: [
        .iOS(.v26),
        .macOS(.v15), // swift-test baseline only; not a shipping target.
    ],
    products: [
        .library(name: "ParallaxPlayback", targets: ["ParallaxPlayback"]),
    ],
    dependencies: [
        .package(path: "../ParallaxCore"),
    ],
    targets: [
        .target(
            name: "ParallaxPlayback",
            dependencies: ["ParallaxCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ParallaxPlaybackTests",
            dependencies: ["ParallaxPlayback"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
