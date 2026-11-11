// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ParallaxSubtitles",
    platforms: [
        .iOS(.v26),
        .tvOS(.v26),
        // Test host only: nothing ships on macOS, but `swift test` runs here.
        .macOS(.v26),
    ],
    products: [
        // Dynamic on purpose: this package ships as its own dylib, built against the
        // libass archives below and nothing else, so no other linked library's copy of
        // libass can capture our ass_* calls under dyld's two-level namespace. Never add
        // a playback dependency to this package.
        .library(name: "ParallaxSubtitles", type: .dynamic, targets: ["ParallaxSubtitles"]),
    ],
    dependencies: [
        // Prebuilt static xcframeworks: Libass + freetype/fribidi/harfbuzz/unibreak.
        .package(url: "https://github.com/mpvkit/libass-build.git", from: "0.17.5"),
    ],
    targets: [
        .target(
            name: "CSubtitleBlend",
            dependencies: [
                .product(name: "libass", package: "libass-build"),
            ]
        ),
        .target(
            name: "ParallaxSubtitles",
            dependencies: [
                "CSubtitleBlend",
                .product(name: "libass", package: "libass-build"),
            ],
            // The only fonts subtitles ever render with: unmodified Noto
            // releases, one family programme across every script. `.copy` keeps
            // the directory intact so `SubtitleFontBundle` can enumerate it and
            // resolve each file by its `Fonts/` path.
            resources: [ .copy("Fonts") ],
            swiftSettings: [ .swiftLanguageMode(.v6) ],
            // The prebuilt archives are pure static libraries and declare none of
            // their own system dependencies: libass' CoreText font provider and
            // its iconv-based recoding, plus freetype's zlib, have to be named
            // here. This is the whole link line.
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedLibrary("iconv"),
                .linkedLibrary("z"),
            ]
        ),
        .testTarget(
            name: "ParallaxSubtitlesTests",
            dependencies: ["ParallaxSubtitles"],
            swiftSettings: [ .swiftLanguageMode(.v6) ]
        ),
    ]
)
