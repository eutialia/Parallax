---
name: verify-parallax
description: Use to reproduce, fix and prove a Parallax bug or behavior change on the macOS host: a bug report, a screenshot with "this looks wrong", a Linear issue, or a feature that needs proof it works. Writes a scenario that fails with the reported value, fixes, then shows the same scenario pass. Routes pixel bugs to #Preview renders and motion to Eutialia.
---

# Verify Parallax

The proof for a behavior change in Parallax is a scenario test that runs on the macOS host with `swift test` and no simulator. It fails before the fix with the value the user saw, and passes after it. CI runs the same command, so a fixed bug stays fixed.

`playbooks` drives the bug-fix and feature steps. This skill is its "verify on the matching surface" for this repo.

## How the app is testable

The views are thin. Feature logic lives in `Packages/ParallaxFeatures`. `AppModel` is built from an `AppEnvironment` that holds only the edges: network, disk, keychain, clock, reachability, engines and other hardware.

`Packages/ParallaxFeatures/Tests/ParallaxFeaturesTests/Scenarios/AppWorld.swift` builds the same `AppModel` on fake edges:

| Edge | Fake | Where |
|---|---|---|
| Jellyfin servers | `FakeJellyfinServer` (stateful) | `Packages/ParallaxJellyfin/Sources/ParallaxJellyfinTestSupport/` |
| SMB connections | `FakeSMBWorld` (`world.nas`) under the real pool | `Packages/ParallaxFileBrowse/Sources/ParallaxFileBrowseTestSupport/` |
| Playback engines | `FakePlaybackEngine` (`world.engine`) | `ParallaxPlaybackTestSupport` |
| Time | `TestClock` (`world.clock`) | `ParallaxCoreTestSupport` |
| Keychain, defaults, disk, reachability, Bonjour, Now Playing | Set up in `AppWorld.launch` | `AppWorld.swift` |

Read `AppWorld.swift` before writing anything. Its `Steps`, `Player` and `Readable state` sections are the vocabulary. Then copy the nearest file in `Scenarios/`.

## 1. Intake

Read the report: chat text, a screenshot, or a Linear issue (`mcp__plugin_linear_linear__get_issue`, then `extract_images` for attachments). Write down three things before touching code:

- **Steps**: what the user did, as app actions ("sign in", "open Home", "play S1E3", "close the player").
- **Observed**: the value on screen, literally ("Continue Watching shows S1E3 at 0:00").
- **Expected**: the value that should be there.

A screenshot is ground truth for what was on screen. Translate it into the state a view renders, and name the property that holds it.

## 2. Classify

| The bug is about | Prove it with | Who judges |
|---|---|---|
| What the app shows or does: routing, lists, labels, resume points, errors, retries, auto-advance, sign-in, persistence | A scenario on the host (section 3) | You |
| Static pixels: size, alignment, clipping, color, material | A `#Preview` of the exact state, rendered with `RenderPreview`; see "Pixels" below | Eutialia judges before and after |
| Real decoding: a codec, a stream, VLC or AVFoundation behavior | The engine suites (`ParallaxPlayback` on the host, `ParallaxPlaybackVLC` on the simulator) or `scripts/playback-lab` | You |
| Motion: springs, transitions, timing feel | Nothing automated | Eutialia on device |
| tvOS focus movement | `swift-focusengine-pro` review | Eutialia on device |

If a behavior bug can't be written as a scenario, its logic still lives in a SwiftUI view. Move that logic into `ParallaxFeatures` first, as a method on `AppModel` or a feature model with a one-line call in the view. Then write the scenario. That move is part of the fix.

## 3. Reproduce with a scenario

Put the scenario in `Scenarios/`. Add to the file for its feature, or start a new one. One scenario is one user story. Name it the way the bug report reads, as the behavior that should hold.

```swift
@MainActor
@Suite("Sign in", .scaledTimeLimit())
struct SignInScenarios {
    @Test("signing in with a wrong password shows the server's error and stays on login")
    func wrongPasswordStaysOnLogin() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana", password: "hunter2")
        let world = try await AppWorld.launch()
        // drive world.app through the methods the views call, then assert what the view renders
    }
}
```

Rules:

- **Drive like a user.** Call `world.app` through the same methods the views call. Never reach into a service to set state the user couldn't set.
- **Assert rendered state.** Use literal expected values on what a view shows: router destination, list contents, labels, error text, selection, the presenter's request, the engine's loaded asset.
- **Pin the neighbor.** When the fix narrows a rule, add a second scenario where the rule must still fire. Examples: a resume point that clears at 95% of the length, or a sign-out on a rejected token. Without it, a fix that deletes the rule also passes.
- **Fake only the edges.** If you need a new endpoint on `FakeJellyfinServer`, add it with jellyfin-sdk's `Paths` and model types. An unhandled route fails loudly, which tells you what to add.
- **One file.** Keep a new scenario in a single file. If it needs a step `AppWorld` lacks, add a `private extension AppWorld` in that file. Promote it to `AppWorld.swift` only when a second scenario needs it.
- **No wall clock.** Time moves only through `world.clock.advance(by:)`, after `try await world.clock.waitForSleep(dueIn:)` names the sleep you mean. Wait for async state with `try await world.until { ... }`. A `Task.sleep` in a scenario is a bug.
- **Prove "not yet" and "never" on the clock.** `advance` returns before the woken work runs, so a state read right after it shows the state from before the wake. Assert `world.clock.pendingSleeps` instead: `.first == .seconds(15)` means nothing fires sooner, `== []` after a cancel means nothing ever will.
- **Time limit.** Every scenario `@Suite` carries `.scaledTimeLimit()`. A literal `.timeLimit` fails CI; scale the ceiling, never the assertion.

Run it and show it fail:

```
scripts/verify.sh <SuiteTypeName>
```

The failure must show the observed value from intake. A failure for any other reason doesn't count as a reproduction: a compile error, a missing fake endpoint, a wait that never arrives because the scenario drove the wrong step. Fix the scenario until it fails for the reported reason.

`verify.sh` exits non-zero when the filter matches nothing. Filter by the Swift type name, not the `@Suite` display name.

## 4. Fix

Follow `playbooks` from step 2: binary-search the cause, find the root, plan the smallest fix, and apply `principle-fix-root-causes`. A guard that makes the scenario pass without explaining why the bug happened is not a fix.

## 5. Prove

1. The same `scripts/verify.sh <SuiteTypeName>` now passes. Paste the failing output and the passing output together.
2. `scripts/verify.sh` with no filter passes. That's every package on the host, about a minute.
3. If the fix touched app code, build for iOS and tvOS with the commands in CLAUDE.md.
4. To confirm a flow on a real screen, after the scenario passes and only when the report needs it, use the Xcode MCP `DeviceInteraction*` tools as CLAUDE.md describes. This is extra evidence, never a replacement for the scenario.
5. List what the scenario can't prove (pixels, motion, real decoding, device behavior) as Eutialia's device-test items. Don't claim them.

The scenario stays in the tree as the regression test. When Eutialia grants the commit step, commit it before the fix (`playbooks` bug-fix step 5).

## Pixels

A static pixel bug is proven by a render, not a scenario.

- Add or extend a `#Preview` that shows the exact question, render it with `RenderPreview`, and look. Keep diagnostic previews in the tree.
- For measurements, pin the preview with `traits: .fixedLayout(width:height:)`, add `.previewRuler(trailing:)` from `Parallax/Features/Shared/PreviewRuler.swift`, render once in dark mode, and run `python3 scripts/render-ruler.py --pt-width <width> --scan-row auto`. Numbers come from the script; read the image only for qualitative judgment.
- tvOS renders are 1920 wide. Crop and upscale with `sips` before judging small deltas.
- Present the before and after renders. Eutialia gives the verdict.
