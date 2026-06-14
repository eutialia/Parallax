// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ParallaxFileBrowse",
    platforms: [
        .iOS(.v26),
        .tvOS(.v26),
        .macOS(.v15), // swift-test baseline only; not a shipping target.
    ],
    products: [
        .library(name: "ParallaxFileBrowse", targets: ["ParallaxFileBrowse"]),
    ],
    dependencies: [
        .package(path: "../ParallaxCore"),
        // libsmb2-backed SMB2/3 client (LGPL — dynamically linked per its own Package.swift).
        // Used for directory enumeration only; streaming goes through libVLC's smb:// path.
        .package(url: "https://github.com/amosavian/AMSMB2.git", from: "4.0.3"),
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
            dependencies: ["ParallaxFileBrowse"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
