// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ParallaxFeatures",
    platforms: [
        .iOS(.v26),
        .tvOS(.v26),
        // Test host only: nothing ships on macOS, but `swift test` runs here.
        .macOS(.v26),
    ],
    products: [
        .library(name: "ParallaxFeatures", targets: ["ParallaxFeatures"]),
    ],
    dependencies: [
        .package(path: "../ParallaxCore"),
        .package(path: "../ParallaxJellyfin"),
        .package(path: "../ParallaxFileBrowse"),
        .package(path: "../ParallaxPlayback"),
        .package(path: "../ParallaxSubtitles"),
        // Test-only: one suite drives a real `LibraryRepository` over a hand-built SDK transport.
        .package(url: "https://github.com/jellyfin/jellyfin-sdk-swift.git", exact: "2.1.0"),
    ],
    targets: [
        .target(
            name: "ParallaxFeatures",
            dependencies: [
                "ParallaxCore",
                "ParallaxJellyfin",
                "ParallaxFileBrowse",
                "ParallaxPlayback",
                "ParallaxSubtitles",
            ],
            // The app target's Approachable Concurrency: a nonisolated async function runs on its
            // caller's actor unless it is `@concurrent`. Swift 6 mode already has the rest of it.
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
        .testTarget(
            name: "ParallaxFeaturesTests",
            dependencies: [
                "ParallaxFeatures",
                .product(name: "ParallaxCoreTestSupport", package: "ParallaxCore"),
                .product(name: "ParallaxFileBrowseTestSupport", package: "ParallaxFileBrowse"),
                .product(name: "ParallaxJellyfinTestSupport", package: "ParallaxJellyfin"),
                .product(name: "ParallaxPlaybackTestSupport", package: "ParallaxPlayback"),
                .product(name: "ParallaxTestScaling", package: "ParallaxCore"),
                .product(name: "JellyfinAPI", package: "jellyfin-sdk-swift"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
    ]
)
