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
        .library(name: "ParallaxPlaybackTestSupport", targets: ["ParallaxPlaybackTestSupport"]),
    ],
    dependencies: [
        .package(path: "../ParallaxCore"),
        .package(
            url: "https://github.com/virtualox/vlckit-spm",
            exact: "4.0.0-alpha.19"
        ),
    ],
    targets: [
        .target(
            name: "ParallaxPlayback",
            dependencies: [
                "ParallaxCore",
                .product(name: "VLCKitSPM", package: "vlckit-spm"),
            ],
            swiftSettings: [ .swiftLanguageMode(.v6) ]
        ),
        .target(
            name: "ParallaxPlaybackTestSupport",
            dependencies: ["ParallaxPlayback", "ParallaxCore"],
            swiftSettings: [ .swiftLanguageMode(.v6) ]
        ),
        .testTarget(
            name: "ParallaxPlaybackTests",
            dependencies: ["ParallaxPlayback", "ParallaxPlaybackTestSupport"],
            swiftSettings: [ .swiftLanguageMode(.v6) ]
        ),
    ]
)
