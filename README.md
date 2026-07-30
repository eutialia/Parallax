# Parallax

A native media player for iPhone, iPad, and Apple TV, built for [Jellyfin](https://jellyfin.org) servers and SMB/NAS shares. Swift and SwiftUI, iOS 26.

## Screenshots

<!-- screenshots: drop 4-6 images into docs/screenshots/ and reference them here -->
| Home | Library | Player |
|------|---------|--------|
| _coming soon_ | _coming soon_ | _coming soon_ |

## Features

- Sign in to multiple Jellyfin servers, with a password or Quick Connect
- Continue Watching, Next Up, watched state, and favorites stay in sync across every screen
- Plays files directly when the format is compatible and falls back to remux or transcode when it isn't
- Browses SMB shares and plays straight from them, with Bonjour discovery. No media server required.
- External subtitle matching, language-aware track selection, and subtitle styling with a live preview
- iPadOS 26 sidebar layout, Liquid Glass, BlurHash artwork placeholders

## Known limitations

Problems Parallax can't fix on its own, or could only fix with trade-offs it doesn't want to make:

- **Jellyfin 10.10 or newer is required.** Older servers don't report modern HDR video-range types, so Parallax assumes the worst and may transcode files that could have played directly.
- **Subtitles can run early after a seek on Jellyfin 11 and older.** When the server transcodes a file with long gaps between keyframes (common with AV1), it starts the stream at a keyframe before the requested position while its timeline claims the exact position. External subtitles then lead by that fixed gap after a resume or seek, and no player can line the two up. Jellyfin 12 fixes this on the server.
- **No seamless quality switching.** Jellyfin serves one rendition per session; there is no adaptive ladder to move across. Changing quality opens a new stream, with a brief reload.
- **TrueHD Atmos doesn't survive transcoding.** Apple's player can't take a TrueHD bitstream, so the server re-encodes it to AAC 5.1. Spatial audio still works, but the Atmos object metadata is gone. Dolby Digital Plus (E-AC-3) Atmos passes through intact.
- **Dual-layer Dolby Vision (profile 7) plays as HDR10.** Apple hardware can't use the enhancement layer, so the server sends the HDR10 base layer.
- **Some formats always transcode in this release.** Apple's decoder can't open VC-1, MPEG-2, AVI, and similar older formats, and the second playback engine that will handle them natively isn't ready yet, so the server transcodes them for now.

## Get it

The app is coming to the App Store (link to follow). The App Store build is compiled from this repository; the price covers the Apple developer membership and ongoing development.

To build it yourself you need Xcode 26. Clone the repo, open `Parallax.xcodeproj`, and run; simulator builds work as-is. For device builds, supply your signing team once (it stays out of git): `echo 'DEVELOPMENT_TEAM = YOURTEAMID' > Config/Signing.local.xcconfig`. App logic lives in the local Swift packages under `Packages/`; the app target is UI and wiring.

## License

Parallax is open source under the [GNU GPLv3](LICENSE).

You can read, build, modify, and run it, and redistribute it under the GPL's terms. One consequence is worth spelling out: Apple's App Store terms are incompatible with the GPL, so only the copyright holder can publish this app there. If someone else uploads Parallax or a derivative to the App Store, paid or free, that violates the license and I will have it taken down. If you just want the app without building it, buy the App Store version.

## Contributing

Bug reports and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Contributions need a small extra license grant so the App Store build can keep shipping. It's explained there.

## Credits

Third-party components and attributions are listed in [CREDITS.md](CREDITS.md).
