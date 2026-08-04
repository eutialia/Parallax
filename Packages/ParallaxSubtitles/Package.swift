// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ParallaxSubtitles",
    platforms: [
        .iOS(.v26),
        .tvOS(.v26),
    ],
    products: [
        // Dynamic on purpose. The app also links VLCKit, whose dylib re-exports an
        // older private copy of libass; a static link here lets the linker bind our
        // ass_* calls to VLC's symbols instead of ours. Shipping this package as its
        // own dylib — built against the libass archives below and nothing else — keeps
        // both copies apart under dyld's two-level namespace. Never add a VLCKit or
        // playback dependency to this package.
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
            swiftSettings: [ .swiftLanguageMode(.v6) ],
            // The prebuilt archives are pure static libraries and declare none of
            // their own system dependencies: libass' CoreText font provider and
            // its iconv-based recoding, plus freetype's zlib, have to be named
            // here. This is the whole link line — no VLCKit, ever.
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
