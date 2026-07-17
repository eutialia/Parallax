// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ParallaxJellyfin",
    platforms: [
        .iOS(.v26),
        .tvOS(.v26),
    ],
    products: [
        .library(name: "ParallaxJellyfin", targets: ["ParallaxJellyfin"]),
    ],
    dependencies: [
        .package(path: "../ParallaxCore"),
        .package(url: "https://github.com/jellyfin/jellyfin-sdk-swift.git", exact: "2.1.0"),
        .package(url: "https://github.com/kean/Nuke.git", from: "12.8.0"),
    ],
    targets: [
        .target(
            name: "ParallaxJellyfin",
            dependencies: [
                "ParallaxCore",
                .product(name: "JellyfinAPI", package: "jellyfin-sdk-swift"),
                .product(name: "Nuke", package: "Nuke"),
                .product(name: "NukeUI", package: "Nuke"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ParallaxJellyfinTests",
            dependencies: [
                "ParallaxJellyfin",
                "ParallaxCore",
                .product(name: "ParallaxCoreTestSupport", package: "ParallaxCore"),
            ],
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
