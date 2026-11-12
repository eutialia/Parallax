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
        // Prebuilt FFmpeg, LGPL 2.1, dynamic frameworks. One maintainer, so the pin is exact and
        // its build.sh is the way to reproduce the binaries.
        .package(url: "https://github.com/superuser404notfound/FFmpegBuild", exact: "3.14.0"),
    ],
    targets: [
        .target(
            name: "ParallaxPlayback",
            dependencies: [
                "ParallaxCore",
                .product(name: "AetherLibavformat", package: "FFmpegBuild"),
                .product(name: "AetherLibavcodec", package: "FFmpegBuild"),
                .product(name: "AetherLibavutil", package: "FFmpegBuild"),
                // Not imported. libavformat and libavcodec load these three at launch, so they
                // have to be embedded with them.
                .product(name: "AetherLibswresample", package: "FFmpegBuild"),
                .product(name: "AetherLibdav1d", package: "FFmpegBuild"),
                .product(name: "AetherLibzvbi", package: "FFmpegBuild"),
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
                // The segment tests read MP4 back through libavformat, as an independent reader.
                .product(name: "AetherLibavformat", package: "FFmpegBuild"),
                .product(name: "AetherLibavcodec", package: "FFmpegBuild"),
                .product(name: "AetherLibavutil", package: "FFmpegBuild"),
                .product(name: "ParallaxCoreTestSupport", package: "ParallaxCore"),
                .product(name: "ParallaxTestScaling", package: "ParallaxCore"),
            ],
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: [ .swiftLanguageMode(.v6) ]
        ),
    ]
)
