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
            name: "ParallaxPlayback",
            dependencies: [
                "ParallaxCore",
                .target(name: "MobileVLCKit", condition: .when(platforms: [.iOS])),
                .target(name: "TVVLCKit", condition: .when(platforms: [.tvOS])),
            ],
            swiftSettings: [ .swiftLanguageMode(.v6) ]
        ),
        .target(
            name: "ParallaxPlaybackTestSupport",
            dependencies: [
                "ParallaxPlayback",
                "ParallaxCore",
                // Never add ParallaxCoreTestSupport here: it's a SECOND product of the
                // ParallaxCore package, and a sibling product drags in a duplicate
                // ParallaxCore target when this reaches the app-hosted ParallaxTests
                // bundle, breaking `as? AppError` casts. ParallaxTestScaling is safe —
                // it's the only ParallaxCore-package product with no ParallaxCore dep.
                .product(name: "ParallaxTestScaling", package: "ParallaxCore"),
            ],
            swiftSettings: [ .swiftLanguageMode(.v6) ]
        ),
        .testTarget(
            name: "ParallaxPlaybackTests",
            dependencies: [
                "ParallaxPlayback",
                "ParallaxPlaybackTestSupport",
                .product(name: "ParallaxTestScaling", package: "ParallaxCore"),
            ],
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: [ .swiftLanguageMode(.v6) ]
        ),
    ]
)
