// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ParallaxFileBrowse",
    platforms: [
        .iOS(.v26),
        .macOS(.v15), // swift-test baseline only; not a shipping target.
    ],
    products: [
        .library(name: "ParallaxFileBrowse", targets: ["ParallaxFileBrowse"]),
    ],
    dependencies: [
        .package(path: "../ParallaxCore"),
    ],
    targets: [
        .target(
            name: "ParallaxFileBrowse",
            dependencies: ["ParallaxCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ParallaxFileBrowseTests",
            dependencies: ["ParallaxFileBrowse"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
