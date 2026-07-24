# Contributing to Parallax

Bug reports, feature ideas, and pull requests are welcome.

## The contributor grant (read this before opening a PR)

Parallax is GPLv3, and the same code ships to the Apple App Store. Apple's terms are incompatible with the GPL. That works for the maintainer only because a copyright holder isn't bound by their own license, and that exemption doesn't extend to code written by other people. If your PR were merged with nothing further agreed, the next App Store build would infringe your copyright.

So by submitting a contribution to this repository you agree that:

1. Your contribution is licensed to the project under the GPLv3 (inbound = outbound), and
2. You also grant the maintainer (eutialia) a non-exclusive, perpetual, irrevocable, worldwide, royalty-free license to reproduce, modify, sublicense, and distribute your contribution as part of Parallax under any terms, including binary distribution through the Apple App Store.

You keep the copyright to your work. Contributions are voluntary and unpaid. Blink Shell uses the same arrangement for its GPL-licensed App Store app.

## Practical notes

- App logic lives in the local Swift packages under `Packages/`; the app target is UI and wiring.
- `#if os(...)` is allowed only in the app target, never in `Packages/`. CI enforces this.
- Packages must not import SwiftUI or Combine.
- Run the package tests before submitting (the CI workflow shows the schemes and destinations).
- New SwiftPM dependencies must be credited in the in-app About screen
  (`Parallax/Features/Settings/About/Acknowledgements.swift`) and `CREDITS.md`;
  `scripts/check-acknowledgements.sh` enforces this in CI.
- Versioning (maintainer): the app version lives only in `Config/Version.xcconfig`,
  bumped by `scripts/release.sh`, which also creates the matching `vX.Y.Z` tag. CI
  rejects a release tag that disagrees with `MARKETING_VERSION`.
