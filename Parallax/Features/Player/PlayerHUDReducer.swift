import Foundation

/// Pure, platform-agnostic state machine for the tvOS player's HUD floor.
/// No UIKit/SwiftUI: every input is a `RemoteEvent`, every side effect a
/// `PlayerEffect`. Declared `nonisolated` so it stays callable from any context
/// (the app target defaults to `@MainActor` isolation; this logic needs none).
/// Unit-tested in `PlayerHUDReducerTests`.
nonisolated enum PlayerHUDState: Equatable {
    /// Clean screen — nothing drawn over the video.
    case floor
    /// Analog swipe scrub: the video is paused on the preview frame at `progress`,
    /// and Select commits the seek (resuming iff `wasPlaying`).
    case swipeScrub(progress: Double, wasPlaying: Bool)
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
    case pause
    case play
    case seek(progress: Double)
    case togglePlayPause
    case exit
}

nonisolated struct ReduceContext: Equatable {
    let liveProgress: Double
    let durationSeconds: Double
    let isPlaying: Bool
}

nonisolated func reduce(_ state: PlayerHUDState, _ event: RemoteEvent, _ ctx: ReduceContext)
    -> (PlayerHUDState, [PlayerEffect]) {
    func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
    /// The ±10s a left/right click steps, as a fraction of the duration. Matches the
    /// in-HUD skip buttons. Zero when the duration is unknown so a click is a no-op seek.
    let clickStep = ctx.durationSeconds > 0 ? 10.0 / ctx.durationSeconds : 0

    switch state {
    case .floor:
        switch event {
        case .swipeHorizontal(let d):
            return (.swipeScrub(progress: clamp(ctx.liveProgress + d), wasPlaying: ctx.isPlaying), [.pause])
        case .swipeVertical, .click(.up), .click(.down):
            return (.fullHUD, [])
        case .click(.left):
            // No seek effect — the view debounces one seek to the settled target.
            return (.clickSeek(targetProgress: clamp(ctx.liveProgress - clickStep)), [])
        case .click(.right):
            return (.clickSeek(targetProgress: clamp(ctx.liveProgress + clickStep)), [])
        case .select, .playPause:
            return (.floor, [.togglePlayPause])
        case .menu:
            return (.floor, [.exit])
        case .idle:
            return (.floor, [])
        }

    case .swipeScrub(let p, let wasPlaying):
        let confirm: [PlayerEffect] = wasPlaying ? [.seek(progress: p), .play] : [.seek(progress: p)]
        switch event {
        case .swipeHorizontal(let d):
            return (.swipeScrub(progress: clamp(p + d), wasPlaying: wasPlaying), [])
        case .select:
            return (.floor, confirm)
        case .swipeVertical, .click:
            return (.fullHUD, confirm)
        case .menu:
            // Explicit cancel (Back): discard the preview, resume where it was.
            return (.floor, wasPlaying ? [.play] : [])
        case .idle:
            // Timeout commits the scrub. tvOS can drop a Select that lands right after a
            // swipe; committing on idle means that missed confirm never loses the seek.
            return (.floor, confirm)
        case .playPause:
            return (.floor, [.seek(progress: p), .togglePlayPause])
        }

    case .clickSeek(let target):
        switch event {
        case .click(.left):
            // No seek effect — the view debounces one seek to the settled target.
            return (.clickSeek(targetProgress: clamp(target - clickStep)), [])
        case .click(.right):
            return (.clickSeek(targetProgress: clamp(target + clickStep)), [])
        case .swipeHorizontal(let d):
            // Fall back to analog scrub from the current target; pause for the preview.
            return (.swipeScrub(progress: clamp(target + d), wasPlaying: ctx.isPlaying), [.pause])
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
            return (.swipeScrub(progress: clamp(ctx.liveProgress + d), wasPlaying: ctx.isPlaying), [.pause])
        case .menu, .idle:
            return (.floor, [])
        case .playPause:
            return (.fullHUD, [.togglePlayPause])
        case .swipeVertical, .click, .select:
            return (.fullHUD, [])
        }
    }
}
