import Foundation

/// Pure, platform-agnostic state machine for the tvOS player's HUD floor.
/// No UIKit/SwiftUI: every input is a `RemoteEvent`, every side effect a
/// `PlayerEffect`. Declared `nonisolated` so it stays callable from any context
/// (the app target defaults to `@MainActor` isolation; this logic needs none).
/// Unit-tested in `PlayerHUDReducerTests`.
nonisolated enum PlayerHUDState: Equatable {
    /// Clean screen — nothing drawn over the video.
    case floor
    /// Analog swipe scrub: the picture is held on the preview frame at `progress`, and Select
    /// commits the seek. Nothing to remember about the transport — the hold leaves the user's
    /// intent alone, so releasing it restores whatever the intent is by then.
    case swipeScrub(progress: Double)
    /// Discrete ±10s click seeking: the video keeps playing while the minimal scrub
    /// bar previews `targetProgress`, which accumulates one step per left/right click.
    /// The reducer emits NO seek here — the view debounces a single seek to the final
    /// target after the clicks settle (a per-click seek burst thrashes a transcode and
    /// wedges the player). Leaving this state flushes that pending seek.
    case clickSeek(targetProgress: Double)
    /// Full chrome (scrubber + chips). Focus is native SwiftUI here — the raw press
    /// adapter is unmounted, so clicks/select never reach the reducer; only the
    /// dedicated Play/Pause button, Menu (`.onExitCommand`), and — while the scrubber
    /// holds focus — horizontal pans from the window-level catcher do (the view gates
    /// them, collapsing the chrome into analog `swipeScrub`).
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
    /// Let the picture go again, wherever the intent has ended up. EVERY exit from `.swipeScrub`
    /// emits it, including the cancels — a hold nothing releases is a frozen picture under a
    /// playing glyph.
    case releaseHold
    case seek(progress: Double)
    case togglePlayPause
    case exit
}

nonisolated struct ReduceContext: Equatable {
    let liveProgress: Double
    let durationSeconds: Double
}

nonisolated enum PlayerHUDTuning {
    /// How far one left/right remote click steps the playhead. Matches the in-HUD
    /// skip buttons. Named so the reducer and its tests share ONE source instead of
    /// each re-typing 10.
    static let clickStepSeconds: Double = 10
}

nonisolated func reduce(_ state: PlayerHUDState, _ event: RemoteEvent, _ ctx: ReduceContext)
    -> (PlayerHUDState, [PlayerEffect]) {
    /// The click step as a fraction of the duration. Zero when the duration is
    /// unknown so a click is a no-op seek.
    let clickStep = ctx.durationSeconds > 0 ? PlayerHUDTuning.clickStepSeconds / ctx.durationSeconds : 0

    // Incomplete media whose runtime never resolved plays with an indefinite duration
    // (`durationSeconds` is NaN → `> 0` is false): there's no scrubbable timeline. Analog swipe +
    // ±10s click events are inert so they can't PAUSE the video into a dead, non-committable,
    // information-free scrub surface (the seek effect is swallowed downstream by `dur > 0`, and the
    // scrub bar renders blank when indeterminate). Vertical (full HUD), play/pause, select, and
    // menu stay live.
    if !(ctx.durationSeconds > 0) {
        switch event {
        case .swipeHorizontal, .click(.left), .click(.right):
            return (state, [])
        default:
            break
        }
    }

    switch state {
    case .floor:
        switch event {
        case .swipeHorizontal(let d):
            return (.swipeScrub(progress: (ctx.liveProgress + d).unitClamped), [.holdStillFrame])
        case .swipeVertical, .click(.up), .click(.down):
            return (.fullHUD, [])
        case .click(.left):
            // No seek effect — the view debounces one seek to the settled target.
            return (.clickSeek(targetProgress: (ctx.liveProgress - clickStep).unitClamped), [])
        case .click(.right):
            return (.clickSeek(targetProgress: (ctx.liveProgress + clickStep).unitClamped), [])
        case .select, .playPause:
            return (.floor, [.togglePlayPause])
        case .menu:
            return (.floor, [.exit])
        case .idle:
            return (.floor, [])
        }

    case .swipeScrub(let p):
        // Every exit releases the hold. The commit's `.seek` reconciles the transport on its
        // own, so the trailing release is idempotent there — but on the cancel it is the only
        // thing that unfreezes the picture, and a cancel that emitted nothing (the old
        // `wasPlaying == false` branch) left a Play pressed mid-scrub stranded: intent playing,
        // engine held, nothing to reconcile the two.
        let confirm: [PlayerEffect] = [.seek(progress: p), .releaseHold]
        switch event {
        case .swipeHorizontal(let d):
            return (.swipeScrub(progress: (p + d).unitClamped), [])
        case .select:
            return (.floor, confirm)
        case .swipeVertical, .click:
            return (.fullHUD, confirm)
        case .menu:
            // Explicit cancel (Back): discard the preview, let the picture go.
            return (.floor, [.releaseHold])
        case .idle:
            // Timeout commits the scrub. tvOS can drop a Select that lands right after a
            // swipe; committing on idle means that missed confirm never loses the seek.
            return (.floor, confirm)
        case .playPause:
            return (.floor, [.seek(progress: p), .releaseHold, .togglePlayPause])
        }

    case .clickSeek(let target):
        switch event {
        case .click(.left):
            // No seek effect — the view debounces one seek to the settled target.
            return (.clickSeek(targetProgress: (target - clickStep).unitClamped), [])
        case .click(.right):
            return (.clickSeek(targetProgress: (target + clickStep).unitClamped), [])
        case .swipeHorizontal(let d):
            // Fall back to analog scrub from the current target; pause for the preview.
            return (.swipeScrub(progress: (target + d).unitClamped), [.holdStillFrame])
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
            // Only arrives while the scrubber holds focus (`PlayerView.onPan` gates it):
            // the chrome collapses into the same analog scrub as a floor swipe.
            return (.swipeScrub(progress: (ctx.liveProgress + d).unitClamped), [.holdStillFrame])
        case .menu, .idle:
            return (.floor, [])
        case .playPause:
            return (.fullHUD, [.togglePlayPause])
        case .swipeVertical, .click, .select:
            return (.fullHUD, [])
        }
    }
}
