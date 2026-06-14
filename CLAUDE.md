# Parallax

Jellyfin (primary) + SMB/local (v2) media player, **Apple platforms only** — iOS/iPadOS first (single `iphoneos` target), tvOS later; macOS/visionOS out of scope. App = `Parallax.xcodeproj`; all logic in local SwiftPM packages under `Packages/` (`ParallaxCore` no-deps, `ParallaxJellyfin`, `ParallaxFileBrowse`, `ParallaxPlayback`). Deeper scope lives in Claude memory.

## Xcode MCP — query it for ground truth, don't reason from memory

**On every Swift/SwiftUI change, the Xcode MCP is your source of truth — not recall.** Swift 6.2 / iOS 26 APIs move fast and trained knowledge is stale: `DocumentationSearch` any Apple API you're not certain of *before* writing it, and after *every* edit run `XcodeRefreshCodeIssuesInFile` (or `BuildProject`+`GetBuildLog`) for real compiler diagnostics instead of eyeballing. The MCP's output overrides your guess.

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
- **Review skills:** the Swift skills are a *review-stage* tool, not a before-you-code step — `/code-review` on Swift changes runs the diff-relevant ones as added angles: `swiftui-pro` (views/APIs), `swift-concurrency-pro` (async/isolation), `swift-focusengine-pro` (focus), `swiftui-liquid-glass` (Liquid Glass), each **scoped to the reviewed hunks** (unscoped, they audit the whole repo and surface out-of-diff noise). Fold their in-diff findings into the review output.
- **MCP first, not memory:** any Swift/SwiftUI work starts by querying the Xcode MCP for ground truth — `DocumentationSearch` for unfamiliar Apple APIs, `XcodeRefreshCodeIssuesInFile`/`BuildProject` to verify after editing. Apple-API analog of the context7-before-coding rule; don't guess from recall.
- **HIG before UI verdicts:** when UI *behavior* (not an API) looks off, check Apple's HIG (`DocumentationSearch` / developer.apple.com) for the *intended* behavior before treating it as a bug or coding around it — e.g. the dark-mode base→elevated background lift on a scaled/multitasked iPad window is documented system behavior, not a glitch.
- **Render, don't guess:** never claim a visual outcome (sizes, alignment, materials, chrome) from reasoning alone — prove it with pixels. Add or extend a `#Preview` that exhibits the exact question (e.g. the side-by-side "Action row parity" preview in `CircleGlassButton.swift`), `RenderPreview` it, and *look*. tvOS renders are 1920-wide, so small deltas vanish in the thumbnail — crop + upscale with `sips -c/-z` before judging. Iterate edit→render until the render shows the fix; keep diagnostic previews as permanent assets. A theory that survives two renders is a fact; one that needed three hacks was wrong (the pill/circle height "ruler" saga).
- **Measure with the kit, not ad hoc:** for alignment/size questions, pin the preview `traits: .fixedLayout(width:height:)`, add `.previewRuler(trailing: <token>)` (`PreviewRuler.swift`, DEBUG-only red rules), render ONCE in dark mode (best edge contrast), then `python3 scripts/render-ruler.py --pt-width <fixedLayout width> --scan-row auto` — no path needed (defaults to the newest render); `--crop tr --zoom 3` for an eyes-on crop. The pt run-length output is ~5× cheaper than reading the image, so: numbers from the script, image reads only for *qualitative* judgment. One render answers many measurements; trust the ruler line over absolute pt (`.fixedLayout` canvases render a few pt wider than declared — 393→398 observed).
- **Debug vs Release runtime:** behavior can diverge between the Debug build run from Xcode ("build runtime" — unoptimized, debugger attached) and the Release/archived build ("publish runtime"). A symptom may appear in only one, in *either* direction (memory notes `onExitCommand` flaky in Release only). Before chasing a UI/focus glitch, confirm which config reproduces it rather than assuming the debug run is what ships.
- **Function before polish:** don't block functional work on rough layout; note UI debt, move on.
- **Commits:** conventional; understand the diff. After a fix, **wait for the user's sim/device confirmation** before committing (clean build ≠ approval); commit/push only when asked.
