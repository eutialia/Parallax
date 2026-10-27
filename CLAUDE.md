# Parallax

Parallax is a media player for Apple platforms. Jellyfin and SMB are the primary sources. iOS and iPadOS ship first from a single `iphoneos` target, tvOS follows. macOS ships nothing and is only the test host for the packages; visionOS is out of scope. The repo is public and the app is on the App Store, so anything you write into it is published.

The app target under `Parallax/` is a thin shell. Every piece of logic lives in a local SwiftPM package under `Packages/`, and the packages must build and test without the app.

This file holds only what you would get wrong without being told. Workflow lives in `playbooks`. Eutialia's instructions override anything here.

## Repository notes

- `Parallax/` is the only place `#if os(...)` is allowed.
- `Packages/ParallaxPlaybackVLC` links iOS-only VLCKit, so it is the one package that tests on the simulator, not the host.
- After a clone, recreate the gitignored `Config/Signing.local.xcconfig`, which holds the real team, and run `git config core.hooksPath .githooks`.
- `DESIGN.md` is the design system. Code comments cite it as law; read it before touching visuals.

## Invariants

- **No platform drift.** `#if os(...)` never appears in `Packages/`; pre-commit and CI reject it. UI may differ per platform, logic may not. A feature on one platform exists on all of them unless hardware makes it impossible.
- **Packages import no SwiftUI, UIKit or Combine.** Observation is allowed: `ParallaxFeatures` holds the `@Observable` models the views bind to. A value only UIKit knows (the idiom, a screen size) comes in as a parameter.
- **Logic leaves the views.** A view's `.task`, `.onChange` or button calls one method on `AppModel` or a feature model; the flow itself lives in `ParallaxFeatures`. Anything that touches the network, disk, keychain, clock or hardware reaches the package only through `AppEnvironment`, so `AppWorld` can fake it.
- **Navigation shape.** iPad is a `TabView` with `.sidebarAdaptable` and `TabSection`. iPhone is a bottom `TabView`. Drill-downs use `NavigationStack`. Never a `NavigationSplitView` at the root.
- **Structural layout branches key on `userInterfaceIdiom`, never size class.** Large iPhones report regular width in landscape, and a size-class branch turns them into an iPad.
- **Subtitles render what the author wrote.** App styling is an opt-in override, default off. Colors and positions are kept; fonts are the acceptable loss. Noto is the only font source, bundled; never a system-font fallback.

## Swift skills

Before writing or reviewing code in an area, read its skill. In review, scope each one to the changed hunks; unscoped, they audit the whole repo.

- SwiftUI views and modifiers: `swiftui-pro`.
- async/await, actors, `Sendable`, `AsyncStream`: `swift-concurrency-pro`.
- tvOS focus, `tvFocusSection`, focus state: `swift-focusengine-pro`.
- Glass, materials, toolbar chrome: `swiftui-liquid-glass`. `DESIGN.md` wins on conflict.
- Swift Testing suites and scenarios: `swift-testing-pro`, with `test-audit`.
- An Apple API you are not sure of: `apple-platform-references`, or the Xcode MCP's `DocumentationSearch`. Swift 6.4 and iOS 27 moved past training data, so check before writing.

## Hazards

1. **Headless builds against Xcode's DerivedData.** Without `-derivedDataPath`, `xcodebuild` poisons Xcode's module cache; the symptom is a fake compile error on unchanged lines. Always pass `-derivedDataPath /tmp/dd-<scheme>`.
2. **Parallel heavy jobs.** Run every shell build, test and simulator job through `scripts/heavy.sh`. Xcode MCP previews and device sessions are tool calls it cannot wrap: before one, hold the lock with a background `scripts/heavy.sh sleep <seconds>` and kill it when the session ends. Keep at most one simulator booted and shut down the ones you boot. Run suites sequentially under a shell `timeout`. If any MCP call stalls, stop waiting and go headless.
3. **Her working tree and simulators are live.** She edits alongside you. Never `reset --hard`, `checkout --`, `worktree remove --force`, or `simctl erase` on her checkout or her simulators; if you need a clean state, make a worktree. Never `stash` across diverged branches. Destructive git needs Eutialia to run it or name it.
4. **Git that leaves the machine.** Push feature branches, `main`, and tags; never `--all` or `--mirror`. `main` is PR-only and rebase-merge only, with no admin bypass. Third-party forks get no force-push at all.
5. **Leaking private infrastructure.** No real hostnames, LAN addresses, or team identifiers in anything tracked. Debug launch arguments added for a screenshot pass are reverted, never committed. Plans, research notes, scratch scripts, and lab results stay outside the tree or in the gitignored tool directories.

## Build and test

Headless `xcodebuild` is the default. Reach for the Xcode MCP only for what headless cannot do.

- iOS: `xcodebuild -scheme Parallax -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath /tmp/dd-Parallax build`, or `test`.
- tvOS: `xcodebuild -scheme Parallax -destination 'generic/platform=tvOS Simulator' -derivedDataPath /tmp/dd-Parallax build`.
- Packages: `scripts/verify.sh [filter]` on the host. ParallaxPlaybackVLC runs from its own directory against the simulator, through the `ParallaxPlaybackVLC-Package` scheme; the bare product schemes have no test action.
- `-only-testing:` and the `verify.sh` filter take the Swift type name. The `@Suite` display name matches nothing and fakes a pass.
- Real-keychain suites self-skip on unentitled simulator hosts. A skip is expected, a failure is real.
- Run the tests for what you changed. CI owns the full matrix.

### Xcode MCP

Xcode.app does not need to be running. Open the project with `XcodeOpenWorkspace` on the absolute path to `Parallax.xcodeproj` and pass the identifier it returns as `workspaceIdentifier`; a path is rejected. Close it with `XcodeCloseWorkspace` when done. `XcodeSwitchScheme` and `XcodeSwitchRunDestination` change the active selection Xcode's toolbar shows, so switch back when Eutialia has the project open.

- `RenderPreview` boots a simulator; pass `timeout`.
- `DeviceInteraction*` confirms a flow on a real screen after its host scenario passes. Tap at positions read from the element hierarchy, never from the screenshot. Close the session when done. Motion is never verified this way; that is Eutialia's.
- Never run tests through the MCP: `RunSomeTests` and `RunAllTests` have no timeout and have blocked for eight hours.
- Edit with the native tools, not the MCP's write tools. The `swift-lsp` plugin's `No such module` errors are stale until a build runs.

## Platforms and engines

UI work is done when it holds on every surface it touches, not on the one you rendered.

- **iPhone, iPad, Apple TV.** The floating sidebar only appears at iPad regular width in landscape; portrait renders a top tab bar and hides sidebar bugs.
- **tvOS focus.** Every horizontal band is a `tvFocusSection`, every pushed page applies `tvHidesTabSidebar`, every empty state has a focusable surface. Miss one and the Menu button exits the app or focus dies on a sparse row.
- **Both engines, both sources.** AVKit and VLC, Jellyfin and SMB. Engine choice is invisible to the user by decision.
- **Debug and Release.** They diverge in either direction. Confirm which one reproduces a glitch before chasing it.

## Standing decisions

- Spring settle is the app's life, including on direct manipulation. Tune a spring before deleting it. App-wide motion changes need a deliberate yes, not a side effect of a local fix.
- Chrome is monochrome; color comes from artwork.
- Apple's way first. Follow the Human Interface Guidelines, and start from the simplest system API or the WWDC sample shape. Go custom only when the requirement cannot be met that way, and say which requirement.
- When behavior looks off, check the HIG before calling it a bug. The dark-mode background lift on a scaled iPad window is documented, not a glitch.
- SwiftUI first. Bridge to UIKit only for what SwiftUI cannot do, and keep the bridge as small as the gap.
- Perception over completeness. Prefetch a viewport ahead, never a whole folder.
- Function before polish. Note layout debt and move on.
- When Eutialia reverses a taste call, revert the whole thing, including the pieces that rode along. Do not layer a fix on top.
