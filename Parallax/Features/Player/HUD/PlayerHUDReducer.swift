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

/// What `send` does with a pending click-step commit when the reducer moves on.
nonisolated enum PendingClickStep: Equatable { case keep, flush, drop }

/// The view-side reads of the HUD state: which surfaces are mounted, how the head moves, and what
/// becomes of a debounced click step. Pure functions of the state plus the model facts each one
/// names, so the tvOS view stays a thin caller and every rule is table-tested.
extension PlayerHUDState {
    /// The full chrome is mounted: `.fullHUD`, or an analog scrub that began on its focused
    /// scrubber and previews on the HUD's own bar.
    nonisolated var chromeUp: Bool {
        switch self { case .fullHUD, .swipeScrub(chrome: true): true; default: false }
    }

    /// Any analog swipe scrub, floor or chrome — the head tracks the finger 1:1 (no position
    /// spring) for an accurate, framerate-proof seek. The bubble's timestamp still rolls (see
    /// `scrubDigitRoll`), so 1:1 keeps its life.
    nonisolated var isAnalogScrub: Bool {
        switch self { case .swipeScrub: true; default: false }
    }

    /// The floor's transient scrub surfaces — the ones that dim the video under the lone bar.
    nonisolated var dimsVideo: Bool {
        switch self { case .swipeScrub(chrome: false), .clickSeek: true; default: false }
    }

    /// Whether the floor's lone scrub bar is mounted. False under the chrome, which brings its own
    /// scrubber — including for a swipe that began there.
    ///
    /// The floor case is the whole reason this isn't just a `switch` in the body: a no-HUD swipe
    /// auto-commits back to `.floor`, and unmounting the bar there would fade out the one surface
    /// the concrete indicator's A→B crossing (and the pulse behind it) plays on. So the floor keeps
    /// it for as long as `landing` says a seek is unresolved — the flight, plus the crossing that
    /// the landing itself launches (`PlayerView` adds that linger, because the model drops the
    /// flight on the very beat the crossing starts). The flight also covers a floor-state seek
    /// nobody scrubbed for (a Now Playing scrub, a debounced click-seek that already left
    /// `clickSeek`), which is the same fact and deserves the same bar. And it spans the hop between
    /// the reducer leaving `.swipeScrub` and the commit landing — the preview IS a flight, so there
    /// is no frame in which the bar has nothing to show.
    ///
    /// `loading` is the one exception: a re-anchor raises the frosted cover over the whole screen,
    /// and the bar has no business painting on top of it for the several seconds that takes. The
    /// flight outlives the cover, so the bar comes back for the landing.
    nonisolated func showsFloorScrubBar(landing: Bool, loading: Bool) -> Bool {
        if dimsVideo { return true }
        if case .floor = self { return landing && !loading }
        return false
    }

    /// Whether the head springs to its next position: a discrete step and the landing glide do, an
    /// analog swipe is pinned 1:1 to the finger, and nothing moves at rest so the live dot keeps
    /// its plain tick.
    nonisolated func animatesDiscreteStep(flightAlive: Bool) -> Bool {
        !isAnalogScrub && flightAlive
    }

    /// What `send` does with a pending click-step commit when the reducer moves to `next` on
    /// `event`: an analog swipe taking over drops it (the swipe's own commit carries the target),
    /// leaving for the floor or Select on the chrome's scrubber lands it now, and both click
    /// surfaces keep it while they accumulate.
    nonisolated static func pendingClickStep(after next: PlayerHUDState,
                                             on event: RemoteEvent) -> PendingClickStep {
        switch next {
        case .swipeScrub: .drop
        case .clickSeek: .keep
        case .fullHUD: event == .select ? .flush : .keep
        case .floor: .flush
        }
    }
}
