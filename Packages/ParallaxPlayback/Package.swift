// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ParallaxPlayback",
    platforms: [
        .iOS(.v26),
        .tvOS(.v26),
        // The test host only: no app ships on macOS. It lets `swift test` run these suites
        // without a simulator.
        .macOS(.v26),
    ],
    products: [
        .library(name: "ParallaxPlayback", targets: ["ParallaxPlayback"]),
        .library(name: "ParallaxPlaybackTestSupport", targets: ["ParallaxPlaybackTestSupport"]),
    ],
    dependencies: [
        .package(path: "../ParallaxCore"),
    ],
    targets: [
        .target(
            name: "ParallaxPlayback",
            dependencies: [
                "ParallaxCore",
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
