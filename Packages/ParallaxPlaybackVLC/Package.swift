// swift-tools-version: 6.2
import PackageDescription

// VLCKit has no macOS build, so the VLC engine lives apart from ParallaxPlayback:
// that package must build and test on the macOS host, this one cannot.
let package = Package(
    name: "ParallaxPlaybackVLC",
    platforms: [
        .iOS(.v26),
        .tvOS(.v26),
    ],
    products: [
        .library(name: "ParallaxPlaybackVLC", targets: ["ParallaxPlaybackVLC"]),
        .library(name: "ParallaxPlaybackVLCTestSupport", targets: ["ParallaxPlaybackVLCTestSupport"]),
    ],
    dependencies: [
        .package(path: "../ParallaxCore"),
        .package(path: "../ParallaxPlayback"),
    ],
    targets: [
        // VideoLAN's official 3.7.3 builds, fetched by scripts/fetch-mobilevlckit.sh
        // (~1.7 GB unpacked for the pair, so they are git-ignored rather than
        // committed). VideoLAN ships iOS and tvOS as two separately named modules
        // built from the same source, so the package picks one per platform.
        .binaryTarget(
            name: "MobileVLCKit",
            path: "Vendor/MobileVLCKit.xcframework"
        ),
        .binaryTarget(
            name: "TVVLCKit",
            path: "Vendor/TVVLCKit.xcframework"
        ),
        .target(
            name: "ParallaxPlaybackVLC",
            dependencies: [
                "ParallaxCore",
                "ParallaxPlayback",
                .target(name: "MobileVLCKit", condition: .when(platforms: [.iOS])),
                .target(name: "TVVLCKit", condition: .when(platforms: [.tvOS])),
            ],
            swiftSettings: [ .swiftLanguageMode(.v6) ]
        ),
        .target(
            name: "ParallaxPlaybackVLCTestSupport",
            dependencies: [
                "ParallaxPlaybackVLC",
                // SpyVLCPlayer conforms to VLCPlayerControlling, whose requirements are
                // VLCKit types. SwiftPM's own builds resolve them transitively; Xcode's
                // explicit-module builds do not, and the app-hosted ParallaxTests bundle
                // then fails with "cannot find type 'VLCPlayerControlling'".
                .target(name: "MobileVLCKit", condition: .when(platforms: [.iOS])),
                .target(name: "TVVLCKit", condition: .when(platforms: [.tvOS])),
            ],
            swiftSettings: [ .swiftLanguageMode(.v6) ]
        ),
        .testTarget(
            name: "ParallaxPlaybackVLCTests",
            dependencies: [
                "ParallaxPlaybackVLC",
                "ParallaxPlaybackVLCTestSupport",
                .product(name: "ParallaxCoreTestSupport", package: "ParallaxCore"),
                .product(name: "ParallaxPlaybackTestSupport", package: "ParallaxPlayback"),
                .product(name: "ParallaxTestScaling", package: "ParallaxCore"),
            ],
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: [ .swiftLanguageMode(.v6) ]
        ),
    ]
)
