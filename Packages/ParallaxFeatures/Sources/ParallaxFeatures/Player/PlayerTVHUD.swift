/// The remote player's HUD shell around `reduce`: which surface owns the remote, what the user is
/// doing inside the full chrome, and the rules the reducer stays blind to — the segment button
/// borrowing the floor remote, the cold-start lockout, the initial-load hand-off, the pending
/// click-step commit and the per-state idle timeouts. Every input is a method that returns the
/// side effects for the view to run in order; the view keeps only the timers and focus.
///
/// The chrome's controls are mounted only while `state.chromeUp`, so a fold takes their panels
/// and their scrubber focus with it — neither can outlive the chrome.
public struct PlayerTVHUD: Equatable, Sendable {
    public private(set) var state: PlayerHUDState {
        didSet {
            guard !state.chromeUp else { return }
            interaction = PlayerHUDInteraction()
            scrubberFocused = false
        }
    }
    public var interaction = PlayerHUDInteraction()
    /// The full HUD's scrubber holds focus, as the controls report it. Gates window-level pans
    /// into analog scrub; on any other focused control a swipe stays with the focus engine.
    public var scrubberFocused = false
    /// The first accepted command has landed. The initial-load chrome (the full HUD over the
    /// loading scrim) hands off to the clean floor exactly once; later loading dips keep
    /// whatever HUD state the user is in, so an open menu survives a track-switch re-buffer.
    public private(set) var didBeginPlayback = false

    /// A player that has not begun: the full chrome over the loading scrim.
    public init() { state = .fullHUD }

    /// A fresh surface. The initial load shows the full chrome; a remount after playback began
    /// (a post-failure retry) starts on the clean floor. Click-seek debris a previous mount left
    /// armed is dropped.
    public mutating func surfaceAppeared() -> [PlayerTVHUDEffect] {
        let began = didBeginPlayback
        self = PlayerTVHUD()
        didBeginPlayback = began
        if began { state = .floor }
        return [.dropPendingSeek]
    }

    /// Keyed on acceptance rather than `.playing`, so a mid-session reload doesn't fold a live
    /// swipe-scrub: the gesture is still going to commit, and the model will honor it.
    /// - First acceptance drops the loading chrome to the floor.
    /// - Losing acceptance (a cold re-load, a failure) folds a scrub to wherever it began and
    ///   drops what it stranded: the pending step, the idle timer, the preview, and the hold —
    ///   this exit bypasses the reducer's `.releaseHold`, and a hold nothing releases pins the
    ///   engine paused under a play glyph.
    public mutating func acceptanceChanged(to accepts: Bool) -> [PlayerTVHUDEffect] {
        if accepts {
            guard !didBeginPlayback else { return [] }
            didBeginPlayback = true
            if state.chromeUp { state = .floor }
            return []
        }
        switch state {
        case .swipeScrub, .clickSeek: state = state.chromeUp ? .fullHUD : .floor
        case .floor, .fullHUD: break
        }
        return [.dropPendingSeek, .cancelIdleTimer, .cancelPreview, .endScrubHold]
    }

    /// One remote event through the shell and the reducer.
    public mutating func send(_ event: RemoteEvent, _ ctx: PlayerTVHUDContext) -> [PlayerTVHUDEffect] {
        // While the segment button shows over the floor, the remote acts on IT: Select fires it,
        // a directional reveal lifts the HUD and spends the one-shot. Back still exits and an
        // analog pan still scrubs.
        if state == .floor, ctx.segmentPromptShowing, ctx.isPlaying {
            switch event {
            case .select:
                return [.activateSegmentPrompt, .restartIdleTimer]
            case .click, .swipeVertical:
                state = .fullHUD
                return [.expireSegmentPrompt, .restartIdleTimer]
            case .swipeHorizontal, .menu, .playPause, .idle:
                break
            }
        }

        // Cold start only: nothing has resolved, so there is no duration to seek against and no
        // session to command — only chrome reveal, exit and idle mean anything. A mid-session
        // reload is not this window: the model parks whatever the remote sends.
        if !ctx.acceptsPlaybackCommands {
            switch event {
            case .menu where !didBeginPlayback:
                // Back exits at once (synchronously fencing the in-flight resolve) instead of
                // peeling the loading chrome back to an empty floor.
                return [.player([.exit])]
            case .swipeVertical, .click(.up), .click(.down), .menu, .idle:
                break
            case .swipeHorizontal, .click(.left), .click(.right), .select, .playPause:
                return []
            }
        }

        let (next, effects) = reduce(state, event, ReduceContext(shownProgress: ctx.shownProgress,
                                                                 durationSeconds: ctx.durationSeconds))
        let pending: [PlayerTVHUDEffect] = switch ctx.hasPendingSeek
            ? PlayerHUDState.pendingClickStep(after: next, on: event) : .keep {
        case .drop: [.dropPendingSeek]
        case .flush: [.flushPendingSeek]
        case .keep: []
        }
        state = next
        let batch: [PlayerTVHUDEffect] = effects.isEmpty ? [] : [.player(effects)]
        // A preview outside an analog scrub is a click step: (re)arm the one debounced commit.
        let clickSteps: [PlayerTVHUDEffect] = next.isAnalogScrub ? [] : effects.compactMap {
            if case .preview(let target) = $0 { .scheduleClickSeek(progress: target) } else { nil }
        }
        return pending + batch + clickSteps + [.restartIdleTimer]
    }

    /// Whether a window-level pan reaches `send`. On the floor's states every pan does. Under the
    /// chrome native focus owns navigation; only a horizontal pan while the scrubber holds focus
    /// falls through, starting or feeding the scrub the chrome stays up for.
    public func routesPan(_ event: RemoteEvent) -> Bool {
        guard state.chromeUp else { return true }
        if scrubberFocused, case .swipeHorizontal = event { return true }
        return false
    }

    /// The current state's inactivity timeout, or nil for none. A swipe-scrub commits after the
    /// same quiet time as the click-seek debounce; the click-seek bar lingers 4s (its seek already
    /// landed — idle only drops the bar); the full HUD auto-hides after 4s unless a panel is open
    /// (folding would unmount it), playback is paused (vanishing chrome over a frozen frame reads
    /// as a dead player) or a seek is alive (folding mid-flight would swap the HUD's dot bar for
    /// the floor's line bar in the middle of the crossing). The floor needs no timer.
    public func idleTimeout(desiredPlaying: Bool, flightAlive: Bool) -> Duration? {
        switch state {
        case .floor: nil
        case .swipeScrub: SeekCommitCoalescer.interval
        case .clickSeek: .seconds(4)
        case .fullHUD: !interaction.menuOpen && desiredPlaying && !flightAlive ? .seconds(4) : nil
        }
    }
}

/// The model facts `PlayerTVHUD.send` reads, sampled by the view at the press.
public struct PlayerTVHUDContext: Equatable, Sendable {
    /// The fraction the bar is showing — see `ReduceContext.shownProgress`.
    public var shownProgress: Double
    public var durationSeconds: Double
    public var acceptsPlaybackCommands: Bool
    public var isPlaying: Bool
    /// The segment button is on screen (`SegmentPromptGate.promptVisible` on the floor).
    public var segmentPromptShowing: Bool
    /// A debounced click-step commit is waiting to fire.
    public var hasPendingSeek: Bool

    public init(shownProgress: Double, durationSeconds: Double, acceptsPlaybackCommands: Bool,
                isPlaying: Bool, segmentPromptShowing: Bool, hasPendingSeek: Bool) {
        self.shownProgress = shownProgress
        self.durationSeconds = durationSeconds
        self.acceptsPlaybackCommands = acceptsPlaybackCommands
        self.isPlaying = isPlaying
        self.segmentPromptShowing = segmentPromptShowing
        self.hasPendingSeek = hasPendingSeek
    }
}

/// What the view runs for the shell, in order.
public enum PlayerTVHUDEffect: Equatable, Sendable {
    /// A reducer batch, run as one ordered unit.
    case player([PlayerEffect])
    case flushPendingSeek
    case dropPendingSeek
    /// Arm the one debounced commit for a click step's target.
    case scheduleClickSeek(progress: Double)
    case activateSegmentPrompt
    case expireSegmentPrompt
    case restartIdleTimer
    case cancelIdleTimer
    case cancelPreview
    case endScrubHold
}
