// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ParallaxJellyfin",
    platforms: [
        .iOS(.v26),
        .macOS(.v15), // swift-test baseline only; not a shipping target.
    ],
    products: [
        .library(name: "ParallaxJellyfin", targets: ["ParallaxJellyfin"]),
    ],
    dependencies: [
        .package(path: "../ParallaxCore"),
        .package(url: "https://github.com/jellyfin/jellyfin-sdk-swift.git", exact: "2.1.0"),
    ],
    targets: [
        .target(
            name: "ParallaxJellyfin",
            dependencies: [
                "ParallaxCore",
                .product(name: "JellyfinAPI", package: "jellyfin-sdk-swift"),
            ],
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
