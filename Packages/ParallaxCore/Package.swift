// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ParallaxCore",
    platforms: [
        .iOS(.v26),
    ],
    products: [
        .library(name: "ParallaxCore", targets: ["ParallaxCore"]),
    ],
    targets: [
        .target(
            name: "ParallaxCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ParallaxCoreTests",
            dependencies: ["ParallaxCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
