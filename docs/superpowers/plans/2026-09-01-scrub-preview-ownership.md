# Scrub Preview Ownership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every seek surface (iOS drag, iOS double-tap burst, iOS VoiceOver step, tvOS floor click-seek, tvOS floor swipe, tvOS full-HUD click step, tvOS full-HUD swipe) declares its preview to `PlayerViewModel`, and every bar reads its two indicators back from the model, so the concrete head stays put and the ghost rides the target on all of them.

**Architecture:** The view model already publishes one `SeekFlight` (`.previewing` → `.committed` → `.landing`). We add `virtualPosition` (the flight's `requested` while previewing, else the published clock) and make `PlayerProgressBar`'s shared init derive `played` and `concrete` from the model instead of a caller-supplied fraction. The tvOS reducer stops carrying a progress payload; it emits `.preview(progress:)` / `.cancelPreview` effects computed from `ReduceContext.shownProgress` (fed from `vm.virtualFraction`), so the floor click, the floor swipe, the HUD click step and the HUD swipe are four rows of one tested table. A swipe on the focused HUD scrubber stays in the chrome (`.swipeScrub(chrome: true)`) and previews on the HUD's dot bar; the full HUD is pinned while a flight is alive so the floor's line bar never swaps in mid-crossing. Both tvOS click-step surfaces commit through the one `SeekCommitCoalescer` after the clicks settle; Select on the HUD scrubber means "commit now".

**Tech Stack:** Swift 6.2, SwiftUI, Swift Testing (`@Test`), Xcode 26 headless `xcodebuild`. The Xcode GUI is open on the MAIN checkout, not this worktree: do NOT use the Xcode MCP tools, they would build the wrong tree.

**Spec:** the triage in this session. Root cause: the bar splits only on `vm.flight?.stage == .previewing`; the two tvOS press paths never declare a preview. Shape is per bar, and the line ghost is the floor bar taking over the HUD bar's rect (chrome collapse on swipe, or an idle fold mid-flight).

## Global Constraints

- Worktree: `/Users/eutialia/Developer/Parallax/.claude/worktrees/tvos-scrub-indicator`. Run everything from there with absolute paths. Never touch the main checkout.
- `#if os(tvOS)` only under `Parallax/`, never under `Packages/`. Logic must not differ per platform; only UI packaging may.
- Each task ends in exactly ONE local WIP commit on this worktree branch, message `wip(scrub): task N — <summary>`. Never push, never touch another branch. The controller uncommits the WIP chain before the user's device check, so the commit is scaffolding, not a release.
- Comments only where the code cannot explain itself. Delete, never deprecate. No compatibility shims.
- Every task must leave BOTH platforms compiling. Build commands (run from the worktree root; each takes 1–5 minutes; use a 600000 ms timeout):
  - iOS tests, scoped: `xcodebuild test -project Parallax.xcodeproj -scheme Parallax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:ParallaxTests/<SuiteName> 2>&1 | grep -E "error:|✘|✔|Test run|TEST (SUCCEEDED|FAILED)|BUILD"`
  - tvOS compile: `xcodebuild build -project Parallax.xcodeproj -scheme Parallax -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | grep -E "error:|BUILD"`
  - Swift Testing results do NOT appear in the XCTest "Executed N tests" line; read the `✔` / `✘` lines and `Test run with N tests`.
- Test style: Swift Testing, `@testable import Parallax`, fixtures from `ParallaxTests/Fakes/PlayerViewModelFixtures.swift`. `makeReanchorVM(at:)` lives in `ParallaxTests/PlayerViewModelTests.swift` around line 1170 and returns `(vm, engines)` with a known duration and the clock at the given second.
- `.unitClamped` (`Parallax/Features/Player/HUD/UnitInterval.swift`) is the ONE 0…1 clamp. Never re-type `min(max(x, 0), 1)`.
- `PlayerHUDTuning.clickStepSeconds` (10) is the ONE click step constant.

---

### Task 1: Model publishes the virtual position

**Files:**
- Modify: `Parallax/Features/Player/PlayerViewModel.swift` (next to `concretePosition`, ~line 202)
- Test: `ParallaxTests/PlayerViewModelTests.swift` (the flight suite, after `seekSpanSpansTheCommittedJump` ~line 1993)

**Interfaces:**
- Produces: `PlayerViewModel.virtualPosition: CMTime`, `PlayerViewModel.virtualFraction: Double`, `PlayerViewModel.concreteFraction: Double`. Later tasks read only these three; nothing else on the model changes.

- [ ] **Step 1: Write the failing tests**

Add inside the same suite that holds `seekSpanSpansTheCommittedJump`:

```swift
/// The two positions the bar draws, as the model publishes them: the VIRTUAL one is the
/// gesture's promise while a preview is up and the published clock otherwise (a commit pins
/// that clock on its target), the CONCRETE one is where the picture actually is.
@Test("the virtual position rides the preview, then the pinned clock")
func virtualPositionFollowsThePreviewThenTheClock() async throws {
    let (vm, _) = try await makeReanchorVM(at: 600)
    let duration = CMTimeGetSeconds(vm.currentDuration)
    #expect(CMTimeGetSeconds(vm.virtualPosition) == 600, "no flight: the clock")
    #expect(vm.virtualFraction == 600 / duration)
    #expect(vm.concreteFraction == 600 / duration)

    vm.beginPreview(at: CMTime(seconds: 1_200, preferredTimescale: 600))
    #expect(CMTimeGetSeconds(vm.virtualPosition) == 1_200, "a preview is the bar's promise")
    #expect(CMTimeGetSeconds(vm.concretePosition) == 600, "the picture has not moved")
    #expect(vm.virtualFraction == 1_200 / duration)
    #expect(vm.concreteFraction == 600 / duration)

    vm.updatePreview(to: CMTime(seconds: 1_800, preferredTimescale: 600))
    #expect(vm.virtualFraction == 1_800 / duration)

    await vm.commitSeek(to: CMTime(seconds: 1_800, preferredTimescale: 600))
    #expect(CMTimeGetSeconds(vm.virtualPosition) == 1_800, "the hold pins the clock on the target")
    #expect(vm.concreteFraction == 600 / duration, "the picture is still at A until the engine lands")
}

@Test("a cancelled preview hands the virtual position back to the clock")
func virtualPositionAfterCancel() async throws {
    let (vm, _) = try await makeReanchorVM(at: 600)
    vm.beginPreview(at: CMTime(seconds: 1_200, preferredTimescale: 600))
    vm.cancelPreview()
    #expect(CMTimeGetSeconds(vm.virtualPosition) == 600)
    #expect(vm.flight == nil)
}

@Test("a preview past the end clamps the fraction to the track")
func virtualFractionClamps() async throws {
    let (vm, _) = try await makeReanchorVM(at: 600)
    let duration = CMTimeGetSeconds(vm.currentDuration)
    vm.beginPreview(at: CMTime(seconds: duration * 2, preferredTimescale: 600))
    #expect(vm.virtualFraction == 1)
}
```

If `makeReanchorVM` returns a tuple with a different shape in this file, read its definition and adapt the destructuring; do not change the fixture.

- [ ] **Step 2: Run the suite to see the new tests fail to compile**

Run: `xcodebuild test -project Parallax.xcodeproj -scheme Parallax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:ParallaxTests/PlayerViewModelTests 2>&1 | grep -E "error:|✘|✔|Test run|TEST (SUCCEEDED|FAILED)|BUILD"`
Expected: build error `value of type 'PlayerViewModel' has no member 'virtualPosition'`.

- [ ] **Step 3: Implement**

In `PlayerViewModel.swift`, directly after `concretePosition`:

```swift
/// The position the bar's VIRTUAL indicator draws, and the one every step, click and swipe
/// accumulates on: the gesture's own promise while a preview is up, otherwise the published
/// clock (which a commit pins on its target until the engine lands). `concretePosition` is
/// the other half of the pair — where the picture actually is.
var virtualPosition: CMTime {
    if let flight, flight.stage == .previewing { return flight.requested }
    return currentPosition
}

/// `virtualPosition` as a 0…1 track fraction; 0 when the runtime isn't scrubbable.
var virtualFraction: Double { fraction(of: virtualPosition) }

/// `concretePosition` as a 0…1 track fraction; 0 when the runtime isn't scrubbable.
var concreteFraction: Double { fraction(of: concretePosition) }

private func fraction(of time: CMTime) -> Double {
    guard hasKnownDuration else { return 0 }
    let duration = CMTimeGetSeconds(currentDuration)
    guard duration > 0 else { return 0 }
    return (CMTimeGetSeconds(time) / duration).unitClamped
}
```

- [ ] **Step 4: Run the suite**

Same command as Step 2. Expected: the three new tests `✔`, no `✘`, `TEST SUCCEEDED`.

- [ ] **Step 5: Make the task's single WIP commit and report the changed files**

---

### Task 2: The bar reads both indicators from the model

**Files:**
- Modify: `Parallax/Features/Player/HUD/PlayerScrubBar.swift` (whole file)
- Modify: `Parallax/Features/Player/HUD/PlayerControlsView.swift`: `SeekFlash` (~163), `liveProgressFraction` (~948), `playheadChip` (~966), `scrubber(_:)` (~1093–1271), `seekStep` (~1355), `seekScrubBar` (~1383), `cancelPendingSeek` (~1418)
- Modify: `Parallax/Features/Player/PlayerView.swift` (~721, the floor bar mount)
- Modify: `Parallax/Features/Player/HUD/PlayerProgressBar.swift` (doc comments at ~33 and ~364 that name `init(scrubbingTo:vm:)`)

**Interfaces:**
- Consumes: `vm.virtualPosition`, `vm.virtualFraction`, `vm.concreteFraction` (Task 1).
- Produces: `PlayerProgressBar.init(vm:metrics:mode:playhead:showsBubble:scrubDigitRoll:onScrubChanged:onScrubEnded:reportsPullExclusion:)` (the `scrubbingTo:` parameter is gone). `PlayerScrubBar(metrics:vm:positionAnimation:)` (the `progress:` parameter is gone). Tasks 3 and 4 build on these.

There is no unit test for this task: it is view wiring. The proof is that both platforms compile with the old parameters gone and the `#Preview`s (which use the memberwise init) untouched. After this task the tvOS full-HUD step is visually inert until Task 4; that is expected.

- [ ] **Step 1: `PlayerScrubBar.swift`: drop `progress`, derive from the model**

Replace the struct's stored `progress` and the body's first two modifiers:

```swift
struct PlayerScrubBar: View {
    static let scrubSpring: Animation = .snappy(duration: 0.25, extraBounce: 0)

    let metrics: PlayerMetrics
    let vm: PlayerViewModel
    /// Head/label POSITION animation. Nil pins the head 1:1 to the model's virtual position —
    /// tvOS analog swipe, where the displayed position must equal the value a commit lands on;
    /// a spring glides discrete ±steps (click-seek, double-tap). The bubble's digit roll always
    /// runs on `scrubSpring`, so even a 1:1 head keeps its "aliveness".
    var positionAnimation: Animation? = scrubSpring

    var body: some View {
        PlayerProgressBar(vm: vm, metrics: metrics,
                          mode: .scrub, playhead: .line, showsBubble: true,
                          scrubDigitRoll: Self.scrubSpring,
                          reportsPullExclusion: false)
            .animation(positionAnimation, value: vm.virtualFraction)
            // keep the padding / frame / colorScheme / allowsHitTesting modifiers exactly as they are
    }
}
```

Keep the existing explanatory comments that still apply (the `reportsPullExclusion` one, the pinned-geometry one). Update the header comment: the bar is driven by the model's flight, not by an owner-supplied `progress`.

In the `extension PlayerProgressBar` below it, change the init signature and the two derived fractions:

```swift
init(vm: PlayerViewModel, metrics: PlayerMetrics,
     mode: Mode, playhead: Playhead = .dot, showsBubble: Bool,
     scrubDigitRoll: Animation? = nil,
     onScrubChanged: ((Double) -> Void)? = nil,
     onScrubEnded: ((Double) -> Void)? = nil,
     reportsPullExclusion: Bool = true) {
    let known = vm.hasKnownDuration
    let dur = CMTimeGetSeconds(vm.currentDuration)
    let previewing = vm.flight?.stage == .previewing
    let p = vm.virtualFraction
    let shown = known ? p * dur : CMTimeGetSeconds(vm.currentPosition)
    let remaining = max(0, dur - shown)
    self.init(
        metrics: metrics, mode: mode, playhead: playhead, indeterminate: !known,
        played: known ? p : 0,
        concrete: previewing && known ? vm.concreteFraction : nil,
        // everything below this line is unchanged
```

Delete the local `live` computation and its comment (the chaining rationale lives on `concretePosition` in the model). Rewrite the init's doc comment: the model declares both indicators; the caller brings only packaging (mode, playhead, bubble, handlers).

- [ ] **Step 2: `PlayerControlsView.swift`: iOS surfaces route through the preview**

a. `SeekFlash` (~163): delete the `targetFraction` field and its initialiser argument in `seekStep`.

b. `liveProgressFraction` (~948): delete it. `playheadChip` (~966) reads `let progress = vm.virtualFraction`.

c. `scrubber(_:)` (~1093): delete the `liveProgress` and `displayed` locals. `shownSeconds` becomes `vm.virtualFraction * durSeconds`. Keep `positionValue`.

d. tvOS arm (~1118): `PlayerProgressBar(vm: vm, metrics: m, mode: scrubberFocused ? .focused : .normal, showsBubble: false)`. In `onMoveCommand`, replace `scrubProgress = liveProgress` with `scrubProgress = vm.virtualFraction`. This arm is rewritten in Task 4; here it only needs to compile.

e. iOS drag arm (~1171): `PlayerProgressBar(vm: vm, metrics: m, mode: dragScrubbing ? .scrub : .normal, playhead: .line, showsBubble: dragScrubbing, onScrubChanged: …, onScrubEnded: …)`. Delete both `scrubProgress = frac` lines inside the handlers. Everything else in the two closures stays.

f. VoiceOver adjust (~1247): replace the body with

```swift
.accessibilityAdjustableAction { direction in
    guard playbackReady, durSeconds > 0 else { return }
    resetHideTimer()
    stepSeek(by: direction == .increment ? PlayerHUDTuning.clickStepSeconds
                                          : -PlayerHUDTuning.clickStepSeconds,
             durSeconds: durSeconds)
}
```

g. Add, in the `#if !os(tvOS)` double-tap block next to `seekStep`:

```swift
/// One ±step from the bar's virtual position: the model previews it (opening the split
/// head on the first step) and the shared coalescer commits the settled target — the same
/// accumulate-then-fire-once shape for the double-tap burst and the VoiceOver adjust.
private func stepSeek(by seconds: Double, durSeconds: Double) {
    let target = min(max(CMTimeGetSeconds(vm.virtualPosition) + seconds, 0), durSeconds)
    vm.beginPreview(at: CMTime(seconds: target, preferredTimescale: 600))
    scheduleSeekCommit(to: target)
}
```

h. `seekStep` (~1355): delete the `livePosition`, `base` and `target` lines and the trailing `scheduleSeekCommit(to: target)`; call `stepSeek(by: delta, durSeconds: durSeconds)` instead. Remove `targetFraction:` from the `SeekFlash(...)` call.

i. `seekScrubBar` (~1393): `PlayerScrubBar(metrics: m, vm: vm)`.

j. `cancelPendingSeek` (~1418): add `vm.cancelPreview()` as the first line. A burst whose commit is dropped must not leave the bar split.

k. `@State scrubProgress` (~94): keep it declared for now. The tvOS arm still writes it until Task 4; its iOS readers are all gone after this step.

- [ ] **Step 3: `PlayerView.swift` (~717–724): the floor bar mount loses its value**

```swift
if scrubProgress != nil {
    PlayerScrubBar(metrics: .tv, vm: vm,
                   positionAnimation: isAnalogScrubbing ? nil : PlayerScrubBar.scrubSpring)
        .transition(.opacity)
}
```

`scrubBarProgress` itself is rewritten in Task 3.

- [ ] **Step 4: `PlayerProgressBar.swift` doc comments**: the two mentions of `init(scrubbingTo:vm:)` (~33, ~364) become `init(vm:)`.

- [ ] **Step 5: Build both platforms**

Run the iOS command with `-only-testing:ParallaxTests/PlayerMetricsTests` (fast suite; the point is the compile) and the tvOS build command. Expected: `TEST SUCCEEDED` and `BUILD SUCCEEDED`, no `error:`.

- [ ] **Step 6: Make the task's single WIP commit and report the changed files**

---

### Task 3: Reducer emits previews; PlayerView applies them; HUD swipe stays in the chrome; HUD pinned during a flight

**Files:**
- Modify: `Parallax/Features/Player/HUD/PlayerHUDReducer.swift` (whole file)
- Modify: `Parallax/Features/Player/PlayerView.swift`: `tvPlaybackSurface` (~666–830), `scrubBarProgress` (~837), `isAnalogScrubbing`/`isFullHUD`/`isScrubbing` (~848–857), `pausedScrimEligible` (~873), `onPan` (~882), `send` (~888–967), `syncScrubPreview` (~977, delete), `scheduleClickSeek` (~990), `flushClickSeek`/`cancelClickSeek`/`tvProgress` (~1005–1022), `runEffects`/`apply` (~1030–1060), `restartIdleTimer` (~1082)
- Test: `ParallaxTests/PlayerHUDReducerTests.swift` (rewrite the click-seek and swipe rows)

**Interfaces:**
- Consumes: `vm.virtualFraction`, `vm.beginPreview(at:)`, `vm.cancelPreview()`, `PlayerScrubBar(metrics:vm:positionAnimation:)`.
- Produces:
  ```swift
  nonisolated enum PlayerHUDState: Equatable { case floor, swipeScrub(chrome: Bool), clickSeek, fullHUD }
  nonisolated enum PlayerEffect: Equatable {
      case holdStillFrame, releaseHold, preview(progress: Double), cancelPreview,
           seek(progress: Double), togglePlayPause, exit
  }
  nonisolated struct ReduceContext: Equatable { let shownProgress: Double; let durationSeconds: Double }
  ```
  Task 4 relies on the `.fullHUD + .click(.left/.right)` and `.fullHUD + .select` cells below.

- [ ] **Step 1: Rewrite the reducer tests**

Read the whole test file first. Replace the `transitionTable` rows that mention `.clickSeek(targetProgress:)`, `.swipeScrub(progress:)` and `liveProgress`, and every dedicated click-seek / swipe test, with the following. Keep the file's existing helpers (`referenceDuration`, `clickStep`, `Transition`, the `indeterminate` context).

```swift
private let baseCtx = ReduceContext(shownProgress: 0.5, durationSeconds: referenceDuration)
private let nearStart = ReduceContext(shownProgress: 0.05, durationSeconds: referenceDuration)

private let transitionTable: [Transition] = [
    // floor
    .init(state: .floor, event: .select, ctx: baseCtx, expected: .floor, effects: [.togglePlayPause]),
    .init(state: .floor, event: .playPause, ctx: baseCtx, expected: .floor, effects: [.togglePlayPause]),
    .init(state: .floor, event: .menu, ctx: baseCtx, expected: .floor, effects: [.exit]),
    .init(state: .floor, event: .idle, ctx: baseCtx, expected: .floor, effects: []),
    .init(state: .floor, event: .click(.up), ctx: baseCtx, expected: .fullHUD, effects: []),
    .init(state: .floor, event: .swipeHorizontal(deltaProgress: 0.02), ctx: baseCtx,
          expected: .swipeScrub(chrome: false), effects: [.holdStillFrame, .preview(progress: 0.5 + 0.02)]),
    // A click is a preview the model accumulates on (`shownProgress` is the model's virtual
    // position, so the second click steps from the first's target) and the view debounces.
    .init(state: .floor, event: .click(.left), ctx: baseCtx, expected: .clickSeek, effects: [.preview(progress: 0.5 - clickStep)]),
    .init(state: .floor, event: .click(.right), ctx: baseCtx, expected: .clickSeek, effects: [.preview(progress: 0.5 + clickStep)]),
    .init(state: .floor, event: .click(.left), ctx: nearStart, expected: .clickSeek, effects: [.preview(progress: 0)]),
    // clickSeek
    .init(state: .clickSeek, event: .click(.right), ctx: baseCtx, expected: .clickSeek, effects: [.preview(progress: 0.5 + clickStep)]),
    .init(state: .clickSeek, event: .swipeHorizontal(deltaProgress: 0.02), ctx: baseCtx,
          expected: .swipeScrub(chrome: false), effects: [.holdStillFrame, .preview(progress: 0.5 + 0.02)]),
    .init(state: .clickSeek, event: .click(.down), ctx: baseCtx, expected: .fullHUD, effects: []),
    .init(state: .clickSeek, event: .select, ctx: baseCtx, expected: .floor, effects: [.togglePlayPause]),
    .init(state: .clickSeek, event: .menu, ctx: baseCtx, expected: .floor, effects: []),
    .init(state: .clickSeek, event: .idle, ctx: baseCtx, expected: .floor, effects: []),
    // swipeScrub on the floor: commits carry the model's shown progress; Back cancels.
    .init(state: .swipeScrub(chrome: false), event: .swipeHorizontal(deltaProgress: -0.1), ctx: baseCtx,
          expected: .swipeScrub(chrome: false), effects: [.preview(progress: 0.5 - 0.1)]),
    .init(state: .swipeScrub(chrome: false), event: .select, ctx: baseCtx, expected: .floor, effects: [.seek(progress: 0.5), .releaseHold]),
    .init(state: .swipeScrub(chrome: false), event: .idle, ctx: baseCtx, expected: .floor, effects: [.seek(progress: 0.5), .releaseHold]),
    .init(state: .swipeScrub(chrome: false), event: .click(.up), ctx: baseCtx, expected: .fullHUD, effects: [.seek(progress: 0.5), .releaseHold]),
    .init(state: .swipeScrub(chrome: false), event: .menu, ctx: baseCtx, expected: .floor, effects: [.cancelPreview, .releaseHold]),
    .init(state: .swipeScrub(chrome: false), event: .playPause, ctx: baseCtx,
          expected: .floor, effects: [.seek(progress: 0.5), .releaseHold, .togglePlayPause]),
    // swipeScrub in the chrome: same cells, home is the full HUD.
    .init(state: .swipeScrub(chrome: true), event: .swipeHorizontal(deltaProgress: 0.1), ctx: baseCtx,
          expected: .swipeScrub(chrome: true), effects: [.preview(progress: 0.5 + 0.1)]),
    .init(state: .swipeScrub(chrome: true), event: .select, ctx: baseCtx, expected: .fullHUD, effects: [.seek(progress: 0.5), .releaseHold]),
    .init(state: .swipeScrub(chrome: true), event: .idle, ctx: baseCtx, expected: .fullHUD, effects: [.seek(progress: 0.5), .releaseHold]),
    .init(state: .swipeScrub(chrome: true), event: .menu, ctx: baseCtx, expected: .fullHUD, effects: [.cancelPreview, .releaseHold]),
    .init(state: .swipeScrub(chrome: true), event: .playPause, ctx: baseCtx,
          expected: .fullHUD, effects: [.seek(progress: 0.5), .releaseHold, .togglePlayPause]),
    // fullHUD: the focused scrubber's L/R and pans arrive here; the chrome never drops for them.
    .init(state: .fullHUD, event: .click(.left), ctx: baseCtx, expected: .fullHUD, effects: [.preview(progress: 0.5 - clickStep)]),
    .init(state: .fullHUD, event: .click(.right), ctx: baseCtx, expected: .fullHUD, effects: [.preview(progress: 0.5 + clickStep)]),
    .init(state: .fullHUD, event: .click(.up), ctx: baseCtx, expected: .fullHUD, effects: []),
    .init(state: .fullHUD, event: .select, ctx: baseCtx, expected: .fullHUD, effects: []),
    .init(state: .fullHUD, event: .swipeHorizontal(deltaProgress: 0.02), ctx: baseCtx,
          expected: .swipeScrub(chrome: true), effects: [.holdStillFrame, .preview(progress: 0.5 + 0.02)]),
    .init(state: .fullHUD, event: .menu, ctx: baseCtx, expected: .floor, effects: []),
    .init(state: .fullHUD, event: .idle, ctx: baseCtx, expected: .floor, effects: []),
    .init(state: .fullHUD, event: .playPause, ctx: baseCtx, expected: .fullHUD, effects: [.togglePlayPause]),
]
```

Float equality: expectations are written as the same expression the reducer evaluates (`shown + delta`, then `.unitClamped`), so `==` holds bit for bit. If a row still trips, fix the expression, never loosen the comparison.

Rewrite the dedicated tests:

```swift
@Test("indeterminate runtime: analog and click seeks are inert in every state",
      arguments: [PlayerHUDState.floor, .clickSeek, .fullHUD])
func indeterminateRuntimeIgnoresSeeks(state: PlayerHUDState) {
    for event in [RemoteEvent.swipeHorizontal(deltaProgress: 0.1), .click(.left), .click(.right)] {
        let (next, effects) = reduce(state, event, indeterminate)
        #expect(next == state)
        #expect(effects.isEmpty)
    }
}

@Test("every exit from a swipe scrub releases the hold", arguments: [false, true])
func everySwipeExitReleasesTheHold(chrome: Bool) {
    let exits: [RemoteEvent] = [.select, .idle, .menu, .playPause, .swipeVertical, .click(.up), .click(.left)]
    for event in exits {
        let (next, effects) = reduce(.swipeScrub(chrome: chrome), event, baseCtx)
        #expect(effects.contains(.releaseHold), "\(event) left the picture frozen")
        if case .swipeScrub = next { Issue.record("\(event) did not leave the scrub") }
    }
}

@Test("a swipe delta clamps to the track", arguments: [(0.95, 0.2, 1.0), (0.05, -0.2, 0.0)])
func swipeDeltaClamps(shown: Double, delta: Double, expected: Double) {
    let ctx = ReduceContext(shownProgress: shown, durationSeconds: referenceDuration)
    let (_, effects) = reduce(.swipeScrub(chrome: false), .swipeHorizontal(deltaProgress: delta), ctx)
    #expect(effects == [.preview(progress: expected)])
}
```

Delete every old test that constructs `.clickSeek(targetProgress:)`, `.swipeScrub(progress:)` or `ReduceContext(liveProgress:)`.

- [ ] **Step 2: Run the reducer suite; expect a compile failure**

Run the iOS command with `-only-testing:ParallaxTests/PlayerHUDReducerTests`. Expected: `error:` lines about `.clickSeek` payloads / `shownProgress`.

- [ ] **Step 3: Rewrite `PlayerHUDReducer.swift`**

```swift
import Foundation

/// Pure, platform-agnostic state machine for the tvOS player's HUD. No UIKit/SwiftUI: every
/// input is a `RemoteEvent`, every side effect a `PlayerEffect`. It carries NO progress of its
/// own — the target of a scrub is the view model's flight, read back through
/// `ReduceContext.shownProgress` — so the state is only *which surface owns the remote*.
/// Unit-tested in `PlayerHUDReducerTests`.
nonisolated enum PlayerHUDState: Equatable {
    /// Clean screen — nothing drawn over the video.
    case floor
    /// Analog swipe scrub: the picture is held on the preview frame. `chrome` says where it
    /// began and therefore which bar previews it and where a commit or cancel returns: a floor
    /// swipe on the lone line bar, back to `.floor`; a swipe on the focused HUD scrubber on the
    /// HUD's own dot bar, back to `.fullHUD` — the chrome never drops for it.
    case swipeScrub(chrome: Bool)
    /// Discrete ±10s click seeking on the floor: the video keeps playing while the lone bar
    /// previews the accumulated target. The reducer emits NO seek — the view debounces one
    /// commit after the clicks settle (a per-click seek burst thrashes a transcode).
    case clickSeek
    /// Full chrome (scrubber + chips). Focus is native SwiftUI here — the raw press adapter is
    /// unmounted, so only the focused scrubber's own L/R step, Select, horizontal pans, the
    /// Play/Pause button and Menu reach the reducer.
    case fullHUD
}

nonisolated enum ClickDirection: Equatable { case left, right, up, down }

nonisolated enum RemoteEvent: Equatable {
    case swipeHorizontal(deltaProgress: Double)
    case swipeVertical
    case click(ClickDirection)
    case select
    case menu
    case playPause
    case idle
}

nonisolated enum PlayerEffect: Equatable {
    /// Freeze the picture under the scrub preview. Not a pause: the user's transport intent is
    /// untouched, which is why the glyph keeps drawing the truth through a scrub.
    case holdStillFrame
    /// Let the picture go again, wherever the intent has ended up. EVERY exit from a swipe
    /// scrub emits it, including the cancels — a hold nothing releases is a frozen picture
    /// under a playing glyph.
    case releaseHold
    /// The bar's promise moved: the view model previews `progress`, opening the concrete/virtual
    /// split on the first one. The reducer's only channel for a target.
    case preview(progress: Double)
    /// The gesture ended with nothing to commit; the model hands the bar back.
    case cancelPreview
    case seek(progress: Double)
    case togglePlayPause
    case exit
}

nonisolated struct ReduceContext: Equatable {
    /// The fraction the bar is showing — the model's virtual position: a live preview's target
    /// while one is up, otherwise the published clock. Every step and swipe accumulates on it.
    let shownProgress: Double
    let durationSeconds: Double
}

nonisolated enum PlayerHUDTuning {
    /// How far one left/right remote click steps the playhead. Matches the in-HUD skip buttons.
    static let clickStepSeconds: Double = 10
}

nonisolated func reduce(_ state: PlayerHUDState, _ event: RemoteEvent, _ ctx: ReduceContext)
    -> (PlayerHUDState, [PlayerEffect]) {
    let clickStep = ctx.durationSeconds > 0 ? PlayerHUDTuning.clickStepSeconds / ctx.durationSeconds : 0
    let shown = ctx.shownProgress
    func preview(_ progress: Double) -> PlayerEffect { .preview(progress: progress.unitClamped) }

    // Incomplete media whose runtime never resolved plays with an indefinite duration
    // (`durationSeconds` is NaN → `> 0` is false): there's no scrubbable timeline, so analog and
    // ±10s events are inert — they can't PAUSE the video into a dead, non-committable scrub.
    if !(ctx.durationSeconds > 0) {
        switch event {
        case .swipeHorizontal, .click(.left), .click(.right): return (state, [])
        default: break
        }
    }

    switch state {
    case .floor:
        switch event {
        case .swipeHorizontal(let d):
            return (.swipeScrub(chrome: false), [.holdStillFrame, preview(shown + d)])
        case .swipeVertical, .click(.up), .click(.down):
            return (.fullHUD, [])
        case .click(.left):
            return (.clickSeek, [preview(shown - clickStep)])
        case .click(.right):
            return (.clickSeek, [preview(shown + clickStep)])
        case .select, .playPause:
            return (.floor, [.togglePlayPause])
        case .menu:
            return (.floor, [.exit])
        case .idle:
            return (.floor, [])
        }

    case .swipeScrub(let chrome):
        let home: PlayerHUDState = chrome ? .fullHUD : .floor
        let confirm: [PlayerEffect] = [.seek(progress: shown), .releaseHold]
        switch event {
        case .swipeHorizontal(let d):
            return (state, [preview(shown + d)])
        case .select, .idle:
            // The idle timeout commits: tvOS can drop a Select that lands right after a swipe,
            // so committing on idle means that missed confirm never loses the seek.
            return (home, confirm)
        case .swipeVertical, .click:
            return (.fullHUD, confirm)
        case .menu:
            return (home, [.cancelPreview, .releaseHold])
        case .playPause:
            return (home, [.seek(progress: shown), .releaseHold, .togglePlayPause])
        }

    case .clickSeek:
        switch event {
        case .click(.left):
            return (.clickSeek, [preview(shown - clickStep)])
        case .click(.right):
            return (.clickSeek, [preview(shown + clickStep)])
        case .swipeHorizontal(let d):
            return (.swipeScrub(chrome: false), [.holdStillFrame, preview(shown + d)])
        case .swipeVertical, .click(.up), .click(.down):
            return (.fullHUD, [])
        case .select, .playPause:
            return (.floor, [.togglePlayPause])
        case .menu, .idle:
            return (.floor, [])
        }

    case .fullHUD:
        switch event {
        case .swipeHorizontal(let d):
            return (.swipeScrub(chrome: true), [.holdStillFrame, preview(shown + d)])
        case .click(.left):
            return (.fullHUD, [preview(shown - clickStep)])
        case .click(.right):
            return (.fullHUD, [preview(shown + clickStep)])
        case .menu, .idle:
            return (.floor, [])
        case .playPause:
            return (.fullHUD, [.togglePlayPause])
        case .swipeVertical, .click, .select:
            return (.fullHUD, [])
        }
    }
}
```

- [ ] **Step 4: `PlayerView.swift`: apply the new contract**

a. Helpers (~848–857). Replace `isAnalogScrubbing`, `isFullHUD`, `isScrubbing` with:

```swift
private var isAnalogScrubbing: Bool { if case .swipeScrub = hudState { return true }; return false }

/// The full chrome is mounted: `.fullHUD`, or an analog scrub that began on its focused
/// scrubber and previews on the HUD's own bar.
private var chromeUp: Bool {
    switch hudState { case .fullHUD, .swipeScrub(chrome: true): true; default: false }
}

/// The floor's transient scrub surfaces — the ones that dim the video under the lone bar.
private var isScrubbing: Bool {
    switch hudState { case .swipeScrub(chrome: false), .clickSeek: true; default: false }
}
```

Replace every remaining `isFullHUD` read in the file with `chromeUp`: the adapter mount (~692), `pausedScrimEligible` (~874), `.animation(.chromeToggle, value:)`, the `onChange(of: vm.desiredPlaying)` guard, `onAppear`, the phase-change handler, `send`, `onPan`. `grep -n isFullHUD` must return nothing when done.

b. The HUD mount switch (~726):

```swift
switch hudState {
case .floor, .swipeScrub(chrome: false), .clickSeek:
    EmptyView()
case .fullHUD, .swipeScrub(chrome: true):
    PlayerControlsView(/* unchanged */)
```

c. `scrubBarProgress` (~837): rename, return a Bool, keep its doc comment's floor rationale and add the chrome case:

```swift
private func showsFloorScrubBar(_ vm: PlayerViewModel) -> Bool {
    switch hudState {
    case .swipeScrub(chrome: false), .clickSeek: true
    case .floor: vm.phase != .loading && vm.seekSpan != nil
    case .swipeScrub(chrome: true), .fullHUD: false
    }
}
```

In `tvPlaybackSurface` (~668/717): `let showsScrubBar = showsFloorScrubBar(vm)`, `if showsScrubBar { PlayerScrubBar(…) }`, `.animation(.playerStateCrossfade, value: showsScrubBar)`.

d. Phase-change handler (~812–817): the fold that cancels a stranded preview becomes

```swift
switch hudState {
case .swipeScrub, .clickSeek:
    vm.cancelPreview()
    hudState = chromeUp ? .fullHUD : .floor
default: break
}
```

e. `send` (~936–967). Replace from `let leavingTarget` through `restartIdleTimer()` with:

```swift
let ctx = ReduceContext(shownProgress: vm.virtualFraction,
                        durationSeconds: CMTimeGetSeconds(vm.currentDuration))
let (next, effects) = reduce(hudState, event, ctx)

// The click-step debounce. A pending step is landed NOW when the user leaves for the floor
// or presses Select on the chrome's scrubber, dropped when an analog swipe takes over (its
// own commit carries the target), and kept while either click surface is still accumulating.
if clickSeekCoalescer.pending != nil {
    switch next {
    case .swipeScrub: cancelClickSeek()
    case .clickSeek: break
    case .fullHUD: if event == .select { flushClickSeek(vm) }
    case .floor: flushClickSeek(vm)
    }
}

hudState = next
// The focus mirror only matters under the chrome; clear it on the way out because
// unmounting the HUD may never fire the focus callback with `false`.
if !chromeUp { scrubberHasFocus = false }
runEffects(effects, vm)

// A preview outside an analog scrub is a click step: (re)arm the one debounced commit.
if !isAnalogScrubbing {
    for case .preview(let target) in effects { scheduleClickSeek(to: target, vm) }
}

chromeVisible = chromeUp
restartIdleTimer()
```

f. Delete `syncScrubPreview` (~970–988) and `tvProgress(of:)` (~1018).

g. `runEffects` / `apply` (~1030). Previews are plain model writes and must land on the same beat as the state (the bar reads the model), so they run synchronously with `.exit`; engine effects keep their ordered task.

```swift
private func runEffects(_ effects: [PlayerEffect], _ vm: PlayerViewModel) {
    var engineEffects: [PlayerEffect] = []
    for effect in effects {
        switch effect {
        case .exit:
            exitPlayer()
        case .preview(let progress):
            let dur = CMTimeGetSeconds(vm.currentDuration)
            guard dur > 0 else { continue }
            vm.beginPreview(at: CMTime(seconds: progress * dur, preferredTimescale: 600))
        case .cancelPreview:
            vm.cancelPreview()
        case .holdStillFrame, .releaseHold, .seek, .togglePlayPause:
            engineEffects.append(effect)
        }
    }
    guard !engineEffects.isEmpty else { return }
    Task { for effect in engineEffects { await apply(effect, vm) } }
}
```

In `apply`, replace the `.exit` case with `case .preview, .cancelPreview, .exit: break` and a one-line comment that these are applied synchronously in `runEffects`.

h. `restartIdleTimer` (~1082): the `.fullHUD` guard gains the pin:

```swift
case .fullHUD:
    // Pinned while a seek is alive: folding to the floor mid-flight would swap the HUD's
    // dot bar for the floor's line bar in the middle of the crossing.
    guard !trackMenuOpen, viewModel?.desiredPlaying == true, viewModel?.flight == nil else { return }
```

Next to `.onChange(of: vm.desiredPlaying)` add the release:

```swift
// The flight ending is what un-pins the chrome; re-arm the auto-hide then.
.onChange(of: vm.flight == nil) { _, ended in
    guard ended, chromeUp else { return }
    restartIdleTimer()
}
```

i. `onPan` (~882): `if chromeUp { guard scrubberHasFocus, case .swipeHorizontal = event else { return } }`.

- [ ] **Step 5: Run the reducer suite and compile tvOS**

Run the iOS command with `-only-testing:ParallaxTests/PlayerHUDReducerTests`, then the tvOS build command. Expected: every table row `✔`, `TEST SUCCEEDED`, tvOS `BUILD SUCCEEDED`, and `grep -n "isFullHUD\|syncScrubPreview\|tvProgress\|scrubBarProgress" Parallax/Features/Player/PlayerView.swift` returns nothing.

- [ ] **Step 6: Make the task's single WIP commit and report the changed files**

---

### Task 4: The tvOS HUD scrubber hands its step and Select to the reducer

**Files:**
- Modify: `Parallax/Features/Player/HUD/PlayerControlsView.swift`: tvOS init (~45–65), `@State scrubProgress` (~94), `commitScrub` (~1067–1089, delete), tvOS scrubber arm (~1108–1158)
- Modify: `Parallax/Features/Player/PlayerView.swift`: the `PlayerControlsView(…)` call (~734)

**Interfaces:**
- Consumes: `send(.click(_:), vm)`, `send(.select, vm)` (Task 3's reducer cells `.fullHUD + .click(.left/.right)` → `.preview`, `.fullHUD + .select` → flush).
- Produces: two tvOS-only closures on `PlayerControlsView`: `onScrubberStep: (ClickDirection) -> Void`, `onScrubberSelect: () -> Void`.

- [ ] **Step 1: Add the closures to the tvOS init**

Read lines 40–80 to see how `onScrubberFocusChange` and `onActivity` are declared and threaded through the tvOS `#if` init. Add, in the same style and the same `#if os(tvOS)` blocks:

```swift
/// The focused scrubber's left/right step; the reducer turns it into a preview.
let onScrubberStep: (ClickDirection) -> Void
/// Select on the focused scrubber: commit the pending step now.
let onScrubberSelect: () -> Void
```

- [ ] **Step 2: Rewrite the tvOS scrubber arm**

Replace the `#if os(tvOS)` branch of `scrubber(_:)` with:

```swift
#if os(tvOS)
// tvOS: a focusable Button wraps the bar. Left/right reach `onMoveCommand` because the bar
// has no horizontal focusable neighbour; up/down ARE focus navigation to the chips / centre
// transport and must never enter scrub. Both the step and Select go to the reducer, which
// owns the preview → debounced commit the same way it does on the floor. The head ring shows
// only while focused — the bar is its own focus indicator, so the style paints no chrome.
Button {
    onScrubberSelect()
} label: {
    PlayerProgressBar(vm: vm, metrics: m,
                      mode: scrubberFocused ? .focused : .normal, showsBubble: false)
}
.buttonStyle(TVQuietButtonStyle(pressedOpacity: 0.9))
.accessibilityLabel("Playback position")
.accessibilityValue(Text(positionValue))
.focused($scrubberFocused)
.onGeometryChange(for: CGRect.self) { $0.frame(in: .named("hud")) } action: { scrubberFrame = $0 }
.animation(.easeOut(duration: 0.15), value: scrubberFocused)
.onMoveCommand { direction in
    guard playbackReady else { return }
    switch direction {
    case .left: onScrubberStep(.left)
    case .right: onScrubberStep(.right)
    default: break
    }
}
.onChange(of: scrubberFocused) { _, focused in
    onScrubberFocusChange(focused)
    onActivity()
}
#else
```

Delete `commitScrub` and its doc comment. Delete `@State private var scrubProgress` (its last writer was this arm). `scrubGeneration` and `isScrubbing` stay: they are the iOS drag's.

- [ ] **Step 3: Wire it in `PlayerView.swift`**

In the `PlayerControlsView(…)` call (~734) add, next to `onScrubberFocusChange:`:

```swift
onScrubberStep: { send(.click($0), vm) },
onScrubberSelect: { send(.select, vm) },
```

`ClickDirection` is the reducer's enum; `onMoveCommand`'s `MoveCommandDirection` is mapped in the controls, so PlayerView never sees SwiftUI's type.

- [ ] **Step 4: Build tvOS and iOS**

Run the tvOS build command, then the iOS command with `-only-testing:ParallaxTests/PlayerControlsChipFocusTests`. Expected: both succeed; `grep -n "scrubProgress\|commitScrub" Parallax/Features/Player/HUD/PlayerControlsView.swift` returns nothing.

- [ ] **Step 5: Make the task's single WIP commit and report the changed files**

---

### Task 5: Whole-branch verification

**Files:** none new.

- [ ] **Step 1: Run every player suite on iOS**

`xcodebuild test -project Parallax.xcodeproj -scheme Parallax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:ParallaxTests/PlayerHUDReducerTests -only-testing:ParallaxTests/PlayerViewModelTests -only-testing:ParallaxTests/PlayerViewModelSegmentTests -only-testing:ParallaxTests/ScrubDeltaPulseTests -only-testing:ParallaxTests/SeekHoldTests -only-testing:ParallaxTests/PlayerMetricsTests -only-testing:ParallaxTests/PlayerControlsChipFocusTests -only-testing:ParallaxTests/PlaybackPresenterTests 2>&1 | grep -E "error:|✘|Test run|TEST (SUCCEEDED|FAILED)"`

Expected: no `✘`, `TEST SUCCEEDED`.

- [ ] **Step 2: tvOS build, warnings included**

`xcodebuild build -project Parallax.xcodeproj -scheme Parallax -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | grep -E "error:|warning:.*Parallax/Features/Player|BUILD"`

Expected: `BUILD SUCCEEDED`, no new warnings in `Features/Player`.

- [ ] **Step 3: Dead-reference sweep**

`grep -rn "scrubbingTo\|liveProgress\b\|targetProgress\|targetFraction\|syncScrubPreview\|tvProgress(\|scrubBarProgress\|isFullHUD\|commitScrub" Parallax ParallaxTests --include='*.swift'` must return nothing.

- [ ] **Step 4: Report `git log --oneline main..HEAD` and `git diff --stat main`**
