# Credits & Third-Party Attributions

## Swift package dependencies

| Component | License | Role |
|-----------|---------|------|
| [jellyfin-sdk-swift](https://github.com/jellyfin/jellyfin-sdk-swift) | *none declared upstream*¹ | Jellyfin API client |
| [Get](https://github.com/kean/Get) | MIT | HTTP transport (via the Jellyfin SDK) |
| [Nuke](https://github.com/kean/Nuke) | MIT | Image loading & caching |
| [AMSMB2](https://github.com/amosavian/AMSMB2) | LGPL-2.1 | SMB2/3 client (wraps libsmb2) |
| [SwiftNIO](https://github.com/apple/swift-nio) (+ swift-atomics, swift-collections, swift-system, swift-nio-transport-services) | Apache-2.0 | Local HTTP bridge for SMB playback |
| [VLCKit](https://code.videolan.org/videolan/VLCKit) (via [vlckit-spm](https://github.com/virtualox/vlckit-spm)) | LGPL-2.1 | Alternate playback engine (© VideoLAN) |

¹ The official Jellyfin Swift SDK currently publishes no license file. The Jellyfin
project distributes it for building clients, so the practical risk is small, but an
upstream issue asking for a license declaration is open work. Re-check before wide release.

LGPL note (AMSMB2/libsmb2, VLCKit): Parallax meets the LGPL relink requirement because
the whole app is open source. Anyone can modify these libraries and rebuild the app from
this repository with standard SwiftPM tooling.

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

> **Release TODO:** surface everything on this page in a user-visible
> Acknowledgements / About screen before shipping. CC-BY-SA asks that the credit reach
> end users of the binary, and the LGPL notices belong there too; this repo-level file
> is the interim placement.
