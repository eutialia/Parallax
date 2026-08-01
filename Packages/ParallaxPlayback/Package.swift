// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ParallaxPlayback",
    platforms: [
        .iOS(.v26),
        .tvOS(.v26),
    ],
    products: [
        .library(name: "ParallaxPlayback", targets: ["ParallaxPlayback"]),
        .library(name: "ParallaxPlaybackTestSupport", targets: ["ParallaxPlaybackTestSupport"]),
    ],
    dependencies: [
        .package(path: "../ParallaxCore"),
    ],
    targets: [
        // VideoLAN's official 3.7.3 build, fetched by scripts/fetch-mobilevlckit.sh
        // (~1 GB unpacked, so it is git-ignored rather than committed).
        .binaryTarget(
            name: "MobileVLCKit",
            path: "Vendor/MobileVLCKit.xcframework"
        ),
        .target(
            name: "ParallaxPlayback",
            dependencies: [
                "ParallaxCore",
                "MobileVLCKit",
            ],
            swiftSettings: [ .swiftLanguageMode(.v6) ]
        ),
        .target(
            name: "ParallaxPlaybackTestSupport",
            dependencies: [
                "ParallaxPlayback",
                "ParallaxCore",
                .product(name: "ParallaxCoreTestSupport", package: "ParallaxCore"),
            ],
            swiftSettings: [ .swiftLanguageMode(.v6) ]
        ),
        .testTarget(
            name: "ParallaxPlaybackTests",
            dependencies: [
                "ParallaxPlayback",
                "ParallaxPlaybackTestSupport",
                .product(name: "ParallaxCoreTestSupport", package: "ParallaxCore"),
            ],
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: [ .swiftLanguageMode(.v6) ]
        ),
    ]
)
