// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ParallaxCore",
    platforms: [
        .iOS(.v26),
        .tvOS(.v26),
    ],
    products: [
        // One process-wide copy of AppError/model type metadata is required for
        // cross-boundary `as? AppError` casts in app-hosted test bundles. We do
        // NOT force `type: .dynamic` here: SPM rejects it — a package-test host
        // that also links ParallaxCoreTestSupport gets a static/dynamic name
        // collision on this product. Unrelated to ParallaxSubtitles' `.dynamic`
        // (libass vs VLCKit symbols).
        .library(name: "ParallaxCore", targets: ["ParallaxCore"]),
        .library(name: "ParallaxCoreTestSupport", targets: ["ParallaxCoreTestSupport"]),
        // Zero-dependency CI time scaling for tests. Safe to reach transitively
        // from app-hosted bundles — must stay free of ParallaxCore forever.
        .library(name: "ParallaxTestScaling", targets: ["ParallaxTestScaling"]),
    ],
    targets: [
        .target(
            name: "ParallaxCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // Test-only CI ceiling scaling. No ParallaxCore dependency on purpose:
        // app-hosted bundles may pull this in transitively without duplicating
        // core types. CI detection stays out of shipping code.
        .target(
            name: "ParallaxTestScaling",
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
