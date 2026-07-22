# Parallax

A native media player for iPhone and iPad, built for [Jellyfin](https://jellyfin.org) servers and SMB/NAS shares. Swift and SwiftUI, iOS 26.

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

## Get it

The app is coming to the App Store (link to follow). The App Store build is compiled from this repository; the price covers the Apple developer membership and ongoing development.

To build it yourself you need Xcode 26. Clone the repo, open `Parallax.xcodeproj`, and run — simulator builds work as-is. For device builds, supply your signing team once (it stays out of git): `echo 'DEVELOPMENT_TEAM = YOURTEAMID' > Config/Signing.local.xcconfig`. App logic lives in the local Swift packages under `Packages/`; the app target is UI and wiring.

## License

Parallax is open source under the [GNU GPLv3](LICENSE).

You can read, build, modify, and run it, and redistribute it under the GPL's terms. One consequence is worth spelling out: Apple's App Store terms are incompatible with the GPL, so only the copyright holder can publish this app there. If someone else uploads Parallax or a derivative to the App Store, paid or free, that violates the license and I will have it taken down. If you just want the app without building it, buy the App Store version.

## Contributing

Bug reports and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Contributions need a small extra license grant so the App Store build can keep shipping. It's explained there.

## Credits

Third-party components and attributions are listed in [CREDITS.md](CREDITS.md).
