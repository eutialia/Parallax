# Parallax

Parallax is a media player for Apple platforms. Jellyfin and SMB are the primary sources. iOS and iPadOS ship first from a single `iphoneos` target, tvOS follows. macOS and visionOS are out of scope. The repo is public and the app is on the App Store, so anything you write into it is published.

The app target under `Parallax/` is a thin shell. Every piece of logic lives in a local SwiftPM package under `Packages/`, and the packages must build and test without the app.

This file holds only what you would get wrong without being told. Eutialia's instructions override anything here.

## Repository map

- `Parallax/` – SwiftUI app: navigation, `@Observable @MainActor` wrappers over package state, per-platform UI. The only place `#if os(...)` is allowed.
- `Packages/ParallaxCore` – shared models, keychain, errors. No dependencies. Ships `ParallaxCoreTestSupport`.
- `Packages/ParallaxJellyfin` – Jellyfin client on top of jellyfin-sdk.
- `Packages/ParallaxFileBrowse` – SMB and local browsing.
- `Packages/ParallaxPlayback` – URL-agnostic player. Entry point is `play(url:headers:hints:)`; state leaves as `AsyncStream<PlaybackState>`.
- `Packages/ParallaxSubtitles` – libass client renderer. Deliberately a dynamic product: VLCKit's dylib exports an old libass that captures a naive static link, so its link line must never contain VLCKit.
- `ParallaxTests/` – app-hosted tests. Its local `FakeKeychain` copy is deliberate: linking the test-support product into the app bundle duplicates ParallaxCore and breaks `as AppError` casts.
- `Config/` – `Version.xcconfig` is the only version source. `Signing.local.xcconfig` is gitignored and holds the real team; recreate it after a clone.
- `DESIGN.md` – the design system. Code comments cite it as law; read it before touching visuals.

## Invariants

- **No platform drift.** `#if os(...)` never appears in `Packages/`; pre-commit and CI reject it. UI may differ per platform, logic may not. A feature on one platform exists on all of them unless hardware makes it impossible.
- **Packages import no SwiftUI or Combine.** State crosses into the app as an `AsyncStream` and gets wrapped there.
- **Navigation shape.** iPad is a `TabView` with `.sidebarAdaptable` and `TabSection`. iPhone is a bottom `TabView`. Drill-downs use `NavigationStack`. Never a `NavigationSplitView` at the root.
- **Structural layout branches key on `userInterfaceIdiom`, never size class.** Large iPhones report regular width in landscape, and a size-class branch turns them into an iPad.
- **Subtitles render what the author wrote.** App styling is an opt-in override, default off. Colors and positions are kept; fonts are the acceptable loss. Noto is the only font source, bundled; never a system-font fallback.

## Hazards

1. **Headless builds against Xcode's DerivedData.** Without `-derivedDataPath`, `xcodebuild` writes into Xcode's DerivedData and poisons its module cache; the symptom is a fake compile error on unchanged lines. Always pass `-derivedDataPath /tmp/dd-<scheme>`.
2. **Parallel test runs on one simulator.** They collide and report zero tests as a pass. Run suites sequentially under a shell `timeout`. The MCP test tools have no timeout and have blocked for eight hours; subagents never call them. If any MCP call stalls, stop waiting and go headless.
3. **Her working tree and simulators are live.** She edits alongside you. Never `reset --hard`, `checkout --`, `worktree remove --force`, or `simctl erase` on her checkout or her simulators; if you need a clean state, make a worktree. Never `stash` across diverged branches. Destructive git needs Eutialia to run it or name it.
4. **Git that leaves the machine.** Push feature branches, `main`, and tags; never `--all` or `--mirror`. `main` is PR-only and rebase-merge only, with no admin bypass. A PR keeps as many commits as make it readable; squash when it helps, not by rule. Third-party forks get no force-push at all.
5. **Leaking private infrastructure.** No real hostnames, LAN addresses, or team identifiers in anything tracked. Debug launch arguments added for a screenshot pass are reverted, never committed.

## Build and test

Headless `xcodebuild` is the default. It is deterministic and ignores Xcode's toolbar. Reach for the Xcode MCP only for what headless cannot do.

- App: `xcodebuild -scheme Parallax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/dd-Parallax build`, or `test`.
- Packages run from their own directory with the same destination. Multi-product packages test through `ParallaxCore-Package` and `ParallaxPlayback-Package`; the bare product schemes have no test action.
- Swift Testing results are absent from XCTest's "Executed N tests" line; grep for `✔`. `-only-testing:` takes the type name, not the `@Suite` display name, which matches nothing and fakes a pass.
- Real-keychain suites self-skip on unentitled hosts. A skip is expected, a failure is real.
- Anti-hang deadlines go through `CITimeScale`: scale the ceiling, never the assertion. A CI-only flake is an unscaled deadline before it is a bug.
- Run the tests for what you changed. CI owns the full matrix.

### When the Xcode MCP earns its place

The `xcode` MCP drives a running Xcode. Three uses justify it:

- `RenderPreview` to see a SwiftUI `#Preview`.
- `DocumentationSearch` for an Apple API you are not sure of. Swift 6.2 and iOS 26 moved past training data, so check before writing. The `apple-platform-references` skill covers the same ground offline.
- `XcodeRefreshCodeIssuesInFile` for a per-file diagnostic pass when a full build is overkill.

Its tools act on whatever scheme and destination Xcode's toolbar has selected and cannot change them. Edit with the native tools, not the MCP's write tools. The `swift-lsp` plugin is for hover and jump-to-definition only; its `No such module` errors are stale until a build runs.

## Platforms and engines

UI work is done when it holds on every surface it touches, not on the one you rendered. Name the ones you checked.

- **iPhone, iPad, Apple TV.** The floating sidebar only appears at iPad regular width in landscape; portrait renders a top tab bar and hides sidebar bugs.
- **tvOS focus.** Every horizontal band is a `tvFocusSection`, every pushed page applies `tvHidesTabSidebar`, every empty state has a focusable surface. Miss one and the Menu button exits the app or focus dies on a sparse row.
- **Both engines, both sources.** AVKit and VLC, Jellyfin and SMB. Engine choice is invisible to the user by decision.
- **Debug and Release.** They diverge in either direction. Confirm which one reproduces a glitch before chasing it.

## Proving UI

Never claim a visual outcome from reasoning. Sizes, alignment, materials, and chrome get proven with pixels.

- Add or extend a `#Preview` that shows the exact question, render it, and look. Keep diagnostic previews. tvOS renders are 1920 wide, so crop and upscale with `sips` before judging small deltas.
- For measurements, pin the preview with `traits: .fixedLayout(width:height:)`, add `.previewRuler(trailing:)` from `PreviewRuler.swift`, render once in dark mode, and run `python3 scripts/render-ruler.py --pt-width <width> --scan-row auto`. Numbers come from the script; read the image only for qualitative judgment.
- A theory that needs a third hack to survive a render is wrong. Fix the root cause, then delete the probes, guards, and lab views the hunt left behind.
- Before and after comparison is hers. Present both renders; do not declare the verdict.
- When behavior looks off, check the HIG before calling it a bug. The dark-mode background lift on a scaled iPad window is documented, not a glitch.
- Function before polish. Note layout debt and move on.

## Standing decisions

- Spring settle is the app's life, including on direct manipulation. Tune a spring before deleting it. App-wide motion changes need a deliberate yes, not a side effect of a local fix.
- Chrome is monochrome; color comes from artwork.
- Apple's way first. Follow the Human Interface Guidelines, and start from the simplest system API or the WWDC sample shape. Go custom only when the requirement cannot be met that way, and say which requirement.
- SwiftUI first. Bridge to UIKit only for what SwiftUI cannot do, and keep the bridge as small as the gap.
- Perception over completeness. Prefetch a viewport ahead, never a whole folder.

## Working with Eutialia

- Her on-device observations are ground truth.
- The ship order is fixed: implement, she device-tests, `/code-review --fix`, commit, PR. She grants each step. A clean build is not approval, and nothing lands on `main` directly.
- Match the ceremony to the change. A one-file edit gets a direct edit, not a worktree and an exploration agent.
- Plans, research notes, scratch scripts, and lab results are never committed. Keep them outside the tree or in the gitignored tool directories.
- When she reverses a taste call, revert the whole thing, including the pieces that rode along. Do not layer a fix on top.
- Code review of Swift changes adds the diff-relevant Swift skills (`swiftui-pro`, `swift-concurrency-pro`, `swift-focusengine-pro`, `swiftui-liquid-glass`), each scoped to the reviewed hunks or they audit the whole repo. Review tool, not a pre-coding ritual.
