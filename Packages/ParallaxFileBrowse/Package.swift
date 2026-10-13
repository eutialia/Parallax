// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ParallaxFileBrowse",
    platforms: [
        .iOS(.v26),
        .tvOS(.v26),
        // Test host only: nothing ships on macOS, but `swift test` runs here.
        .macOS(.v26),
    ],
    products: [
        .library(name: "ParallaxFileBrowse", targets: ["ParallaxFileBrowse"]),
        .library(name: "ParallaxFileBrowseTestSupport", targets: ["ParallaxFileBrowseTestSupport"]),
    ],
    dependencies: [
        .package(path: "../ParallaxCore"),
        // libsmb2-backed SMB2/3 client (LGPL — dynamically linked per its own Package.swift).
        // Used for directory enumeration only; streaming goes through libVLC's smb:// path.
        // Pinned to our fork's parallax-stable (upstream 4.0.3 + a memory-safety patch: heap-owned
        // async request state). Return to an upstream version pin once the patch merges
        // (amosavian/AMSMB2 issues #129/#136).
        .package(url: "https://github.com/eutialia/AMSMB2.git", revision: "365a2c0a0d5af17a48e3d7d9d3d7c12c4ba239cb"),
    ],
    targets: [
        .target(
            name: "ParallaxFileBrowse",
            dependencies: ["ParallaxCore", "AMSMB2"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ParallaxFileBrowseTestSupport",
            dependencies: [
                "ParallaxFileBrowse",
                .product(name: "ParallaxCoreTestSupport", package: "ParallaxCore"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ParallaxFileBrowseTests",
            dependencies: [
                "ParallaxFileBrowse",
                "ParallaxFileBrowseTestSupport",
                .product(name: "ParallaxCoreTestSupport", package: "ParallaxCore"),
                .product(name: "ParallaxTestScaling", package: "ParallaxCore"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
