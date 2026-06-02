# Parallax

Jellyfin (primary) + SMB/local (v2) media player, **Apple platforms only** — iOS/iPadOS first (single `iphoneos` target), tvOS later; macOS/visionOS out of scope. App = `Parallax.xcodeproj`; all logic in local SwiftPM packages under `Packages/` (`ParallaxCore` no-deps, `ParallaxJellyfin`, `ParallaxFileBrowse`, `ParallaxPlayback`). Deeper scope lives in Claude memory.

## Xcode MCP — preferred build/test/diagnose loop

Apple's Xcode MCP (`xcode` = `xcrun mcpbridge`) is wired in. **When Xcode is open on Parallax, use it instead of `xcodebuild`** — it drives the running Xcode and reuses its build+index (structured results, real diagnostics, no second indexer). `swift-lsp`/`sourcekit-lsp` is **disabled on purpose** (re-indexed the whole graph every session for nothing); `XcodeRefreshCodeIssuesInFile` replaces it — **don't re-enable it**.

- **First call each session: `XcodeListWindows`** → `tabIdentifier` (usually `windowtab1`); every other tool needs it. Empty = Xcode not open → use fallback below.
- Tools act on the **scheme + destination selected in Xcode's toolbar**; nothing can change them — if you need a different one, **ask the user to switch it in Xcode**.
- **Edit with native `Edit`/`Write`** (Xcode auto-reloads); don't use `Xcode{Write,Update,MV,RM,MakeDir}`. After editing, run `XcodeRefreshCodeIssuesInFile` (or `BuildProject`+`GetBuildLog`). Native `Grep`/`Glob`/`Read` are fine here.

| Need | Tool |
|---|---|
| Compile-check active scheme | `BuildProject` → `GetBuildLog` (filter `severity`/`pattern`/`glob`) |
| Per-file diagnostics after edit | `XcodeRefreshCodeIssuesInFile` (project-relative path); all issues → `XcodeListNavigatorIssues` |
| Tests | `GetTestList` → `RunSomeTests` (`{targetName,testIdentifier}[]`); whole plan → `RunAllTests` |
| Render a SwiftUI `#Preview` | `RenderPreview` (`sourceFilePath` + 0-based index) |
| Apple API docs | `DocumentationSearch` (complements `context7` for jellyfin-sdk) |

## Headless fallback (Xcode closed)

Schemes: `Parallax` (app), `ParallaxCore`, `ParallaxFileBrowse`, `ParallaxJellyfin`, `ParallaxJellyfinTests`, `ParallaxPlayback`. Configs: `Debug`/`Release`.
- App: `xcodebuild -scheme Parallax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
- **Package tests need an iOS Simulator** (macOS `swift test` fails: NukeUI→`SwiftUICore`). From the package dir:
  `cd Packages/ParallaxJellyfin && xcodebuild test -scheme ParallaxJellyfin -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
  Expect **9 pre-existing Keychain failures** (`errSecMissingEntitlement -34018`) — not regressions; `-only-testing:ParallaxJellyfinTests/<Suite>` to skip.
- **`ParallaxPlayback` tests need `-scheme ParallaxPlayback-Package`** (the bare `ParallaxPlayback` scheme has no test action). Swift Testing (`@Test`) results are absent from the XCTest "Executed N tests" line (reads 0) — grep `✔`/`Test run with N tests` instead.

## Rules

- **Zero platform drift:** `#if os(...)` only in app target `Parallax/`, never `Packages/` (pre-commit + CI enforced). UI may differ per platform; logic must not.
- **Packages import no SwiftUI/Combine:** state crosses as `AsyncStream<PlaybackState>`, wrapped `@Observable @MainActor` in the app. Playback is URL-agnostic: `play(url:headers:hints:)`.
- **Navigation:** iPad = `TabView` `.tabViewStyle(.sidebarAdaptable)` + `TabSection` (iPadOS 26 side panel, like Music/Apple TV); iPhone = bottom `TabView`; **never** a fixed-column `NavigationSplitView` root; drill-downs use `NavigationStack`.
- **Skills first:** before SwiftUI work or review, read & apply this repo's `.claude/skills/` (`swiftui-pro`, `apple-platform-references`).
- **Function before polish:** don't block functional work on rough layout; note UI debt, move on.
- **Commits:** conventional; understand the diff. After a fix, **wait for the user's sim/device confirmation** before committing (clean build ≠ approval); commit/push only when asked.
