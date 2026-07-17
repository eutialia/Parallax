// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ParallaxCore",
    platforms: [
        .iOS(.v26),
        .tvOS(.v26),
    ],
    products: [
        .library(name: "ParallaxCore", targets: ["ParallaxCore"]),
        .library(name: "ParallaxCoreTestSupport", targets: ["ParallaxCoreTestSupport"]),
    ],
    targets: [
        .target(
            name: "ParallaxCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ParallaxCoreTestSupport",
            dependencies: ["ParallaxCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ParallaxCoreTests",
            dependencies: ["ParallaxCore", "ParallaxCoreTestSupport"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
