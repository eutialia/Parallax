// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ParallaxJellyfin",
    platforms: [
        .iOS(.v26),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ParallaxJellyfin", targets: ["ParallaxJellyfin"]),
    ],
    dependencies: [
        .package(path: "../ParallaxCore"),
    ],
    targets: [
        .target(
            name: "ParallaxJellyfin",
            dependencies: ["ParallaxCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ParallaxJellyfinTests",
            dependencies: ["ParallaxJellyfin"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
