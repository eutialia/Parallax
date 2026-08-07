// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ParallaxFileBrowse",
    platforms: [
        .iOS(.v26),
        .tvOS(.v26),
    ],
    products: [
        .library(name: "ParallaxFileBrowse", targets: ["ParallaxFileBrowse"]),
    ],
    dependencies: [
        .package(path: "../ParallaxCore"),
        // libsmb2-backed SMB2/3 client (LGPL — dynamically linked per its own Package.swift).
        // Used for directory enumeration only; streaming goes through libVLC's smb:// path.
        // Pinned to our fork's parallax-stable (upstream 4.0.3 + a memory-safety patch: heap-owned
        // async request state). Return to an upstream version pin once the patch merges
        // (amosavian/AMSMB2 issues #129/#136).
        .package(url: "https://github.com/eutialia/AMSMB2.git", revision: "701793a87e220619e095bf94a77c6cf300aed26a"),
    ],
    targets: [
        .target(
            name: "ParallaxFileBrowse",
            dependencies: ["ParallaxCore", "AMSMB2"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ParallaxFileBrowseTests",
            dependencies: [
                "ParallaxFileBrowse",
                .product(name: "ParallaxTestScaling", package: "ParallaxCore"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
