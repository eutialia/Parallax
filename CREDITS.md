# Credits & Third-Party Attributions

This file mirrors the in-app screen at Settings → About Parallax
(`Parallax/Features/Settings/About/Acknowledgements.swift`, checked by
`scripts/check-acknowledgements.sh` in CI so neither can silently miss a dependency).

## Swift package dependencies

| Component | License | Role |
|-----------|---------|------|
| [jellyfin-sdk-swift](https://github.com/jellyfin/jellyfin-sdk-swift) | *none declared upstream*¹ | Jellyfin API client |
| [Get](https://github.com/kean/Get) | MIT | HTTP transport (via the Jellyfin SDK) |
| [Nuke](https://github.com/kean/Nuke) | MIT | Image loading & caching |
| [AMSMB2](https://github.com/amosavian/AMSMB2) | LGPL-2.1 | SMB2/3 client (wraps libsmb2) |
| [SwiftNIO](https://github.com/apple/swift-nio) (+ swift-atomics, swift-collections, swift-system, swift-nio-transport-services) | Apache-2.0 | Local HTTP bridge for SMB playback |

¹ The official Jellyfin Swift SDK currently publishes no license file. The Jellyfin
project distributes it for building clients, so the practical risk is small.

## Vendored binary frameworks

| Component | License | Role |
|-----------|---------|------|
| [MobileVLCKit](https://code.videolan.org/videolan/VLCKit) 3.7.3 | LGPL-2.1 | Alternate playback engine, iOS/iPadOS (© VideoLAN) |
| [TVVLCKit](https://code.videolan.org/videolan/VLCKit) 3.7.3 | LGPL-2.1 | Alternate playback engine, tvOS (© VideoLAN) |

These are one library under two names: VideoLAN builds VLCKit per platform and ships the
iOS and tvOS products as separately named modules, so the app links whichever matches the
platform it is building for. Neither is resolved through SwiftPM — VideoLAN's official
prebuilt xcframeworks are fetched by `scripts/fetch-mobilevlckit.sh` and linked as local
binary targets; together they are ~1.7 GB unpacked, so they are git-ignored rather than
committed.

LGPL note (AMSMB2/libsmb2, VLCKit): Parallax meets the LGPL relink requirement. The whole
app is open source, so anyone can modify these libraries and rebuild it from this
repository — and VLCKit specifically ships as a **dynamic** framework, so a user-built
replacement can be swapped in without rebuilding the app at all.

## Jellyfin icon (`JellyfinGlyph`)

The Jellyfin mark shown beside the "Jellyfin Server" option (the Add Server menu in
Settings and the logged-out source picker) comes from the
[jellyfin-ux](https://github.com/jellyfin/jellyfin-ux) repository.

- **Source:** `logos/SVG/jellyfin-icon--flat-on-dark.svg`
- **© Jellyfin contributors**, licensed under
  [CC-BY-SA-4.0](https://creativecommons.org/licenses/by-sa/4.0/).
- Used **unmodified**, rendered as a monochrome template glyph solely to indicate
  interoperability with Jellyfin servers (nominative use). It is not Parallax's own
  brand mark; the app's identity is its own `BrandIcon`.
