import Foundation

/// An outer third of the touch surface — the double-tap seek zones. The middle third is no zone.
nonisolated public enum PlayerSeekDirection: Hashable, Sendable {
    case backward, forward
}

/// A double-tap seek burst: the dome, its chevrons and "N seconds", and the scrub bar riding it.
public struct PlayerSeekBurst: Equatable, Sendable {
    public let direction: PlayerSeekDirection
    /// The label: every step in one direction adds to it, a reversal starts over.
    public let seconds: Int
    public let tapPoint: CGPoint
    /// Bumped per tap, so the dome re-fires its ripple.
    public let trigger: Int
    /// The burst clock the bar fades on, matching the dome's own: reset by a reversal (a new
    /// dome), held across same-direction taps.
    public let burstStart: Date
    public let lastTap: Date
}

/// The touch player's chrome: whether it shows, what the user is doing inside it, the drag-scrub
/// and the double-tap seek burst. Owned by the player surface, which derives the system chrome
/// from it and mounts the controls that drive it. Every input is a method returning the side
/// effects for the view to run in order; the view keeps the gesture geometry, the timers and
/// the engine calls.
public struct PlayerTouchChrome: Equatable, Sendable {
    /// The drag-scrub: a finger on the bar, then the commit it hands off, which outlives the
    /// finger. Each drag mints a generation, so a slow commit can't end a newer drag's scrub.
    public enum Scrub: Equatable, Sendable {
        case idle
        case dragging(generation: Int)
        case committing(generation: Int)
    }

    private struct Tap: Equatable, Sendable {
        let date: Date
        let zone: PlayerSeekDirection?
    }

    /// How long the chrome stays up after the last interaction.
    public static let autoHideDelay: Duration = .seconds(3)
    /// A tap in an outer third within this of a previous tap in the SAME third is the second tap
    /// of a pair. The standard iOS double-tap gap — long enough to pair a relaxed double-tap,
    /// short enough that a lone edge tap's toggle reads as instant.
    public static let doubleTapWindow: TimeInterval = 0.3

    public var visible = true
    public var interaction = PlayerHUDInteraction()
    public private(set) var scrub = Scrub.idle
    public private(set) var burst: PlayerSeekBurst?
    private var lastTap: Tap?
    private var lastGeneration = 0

    public init() {}

    /// A finger is on the bar: the chrome collapses into the lone bar over a held frame.
    public var dragScrubbing: Bool {
        if case .dragging = scrub { true } else { false }
    }
    /// A drag-scrub's finger or its commit is live; the centre transport stays out until the seek
    /// lands, so the paused glyph can't flash before the seek's buffering scrim.
    public var scrubInFlight: Bool { scrub != .idle }

    /// The status bar hides with the chrome, and under a drag-scrub, whose lone bar reads as a
    /// clean screen.
    public var statusBarHidden: Bool { !visible || dragScrubbing }
    /// The home indicator follows the same rule as the status bar.
    public var systemOverlaysVisible: Bool { !statusBarHidden }
    /// The pull stands down while a panel owns the screen (a drag inside a list must not drag the
    /// player) and while a finger holds the scrub bar.
    public var pullToDismissEnabled: Bool { !interaction.menuOpen && !dragScrubbing }
    /// The segment button yields the bottom edge to the drag-scrub's lone bar.
    public var segmentPromptEnabled: Bool { !dragScrubbing }

    /// No auto-hide while a panel is open, a finger holds the bar (hiding mid-drag would unmount
    /// the gesture's view and strand the engine held), a pull-to-dismiss drag is live (hiding
    /// collapses the status-bar inset and shears the top bar off the moving card), or playback is
    /// paused — a paused frame with vanishing chrome reads as a dead player.
    public func autoHideEligible(pullDragging: Bool, desiredPlaying: Bool) -> Bool {
        !interaction.menuOpen && !dragScrubbing && !pullDragging && desiredPlaying
    }

    /// The burst draws only over a hidden chrome and a player that accepts commands — the full
    /// HUD's scrubber sits at the burst bar's exact rect, so the two never show together.
    public func showsBurst(playbackReady: Bool) -> Bool {
        burst != nil && playbackReady && !visible
    }

    // MARK: Inputs

    /// The auto-hide timer ran out.
    public mutating func autoHideFired() { visible = false }

    /// Any interaction with the chrome: bring it back and restart the auto-hide.
    public mutating func reveal() -> [PlayerTouchEffect] {
        visible = true
        return [.rearmHide]
    }

    /// One tap-up on the surface. Every tap toggles the chrome the instant it lands — except the
    /// second tap of a pair in one outer third, which HIDES the chrome and starts a ±10s burst, so
    /// the dome and its bar take over a clean surface. While a burst shows, every tap belongs to
    /// it: an outer third steps it, the middle third does nothing, so a stray tap can't raise the
    /// HUD over the affordance. The middle third never seeks; a player that can't seek just
    /// toggles.
    public mutating func tap(zone: PlayerSeekDirection?, at point: CGPoint, now: Date,
                             playbackReady: Bool, durationKnown: Bool) -> [PlayerTouchEffect] {
        // A middle-third tap records a nil zone, so it can never pair with a later outer tap.
        let paired = lastTap.flatMap { now.timeIntervalSince($0.date) < Self.doubleTapWindow ? $0.zone : nil }
        lastTap = Tap(date: now, zone: zone)
        let canSeek = playbackReady && durationKnown

        if burst != nil {
            guard let zone, canSeek else { return [] }
            return seekStep(zone, at: point, now: now)
        }
        guard let zone, canSeek else { return toggle() }
        guard paired == zone else { return toggle() }
        // A first tap that raised the HUD is dropped by this hide; one that lowered it stays down.
        if !dragScrubbing { visible = false }
        return seekStep(zone, at: point, now: now)
    }

    /// Show or hide the chrome. An open menu closes instead, leaving the chrome up. A second
    /// finger's tap never yanks the chrome out from under a drag-scrub — unmounting the bar would
    /// kill the gesture with the frame held.
    public mutating func toggle() -> [PlayerTouchEffect] {
        guard !dragScrubbing else { return [] }
        if interaction.menuOpen {
            interaction = PlayerHUDInteraction()
            visible = true
            return [.rearmHide]
        }
        visible.toggle()
        return visible ? [.rearmHide] : []
    }

    /// A drag on the bar moved. The first move enters the scrub: the auto-hide stops, a queued
    /// burst is dropped (its commit would drag playback back to a stale target) and the picture
    /// is held on the preview frame — the transport intent is untouched.
    public mutating func scrubDragChanged() -> [PlayerTouchEffect] {
        guard !dragScrubbing else { return [] }
        lastGeneration += 1
        scrub = .dragging(generation: lastGeneration)
        burst = nil
        return [.cancelHide, .dropPendingSeek, .cancelBurstDismissal, .beginScrubHold]
    }

    /// The finger lifted at `fraction`. With nothing to commit the bar is handed back and the
    /// picture let go; otherwise one commit seeks there, and the scrub stays in flight until it
    /// lands.
    public mutating func scrubDragEnded(at fraction: Double, canCommit: Bool) -> [PlayerTouchEffect] {
        visible = true
        guard canCommit else {
            scrub = .idle
            return [.rearmHide, .cancelScrub]
        }
        scrub = .committing(generation: lastGeneration)
        return [.rearmHide, .commitScrub(generation: lastGeneration, fraction: fraction)]
    }

    /// A drag's commit returned. A newer drag owns the bar by then and keeps it.
    public mutating func scrubCommitLanded(generation: Int) {
        if scrub == .committing(generation: generation) { scrub = .idle }
    }

    /// VoiceOver's adjust on the bar: one ±10s step. A burst's dome would otherwise keep drawing
    /// its stale label over the step and take the next tap.
    public mutating func accessibilityStep(_ direction: PlayerSeekDirection) -> [PlayerTouchEffect] {
        visible = true
        burst = nil
        return [.rearmHide, .cancelBurstDismissal, .stepSeek(seconds: Self.stepSeconds(direction))]
    }

    /// Another seek-shaped action (an episode jump, a chapter pick) or a track reload: a queued
    /// burst's commit would fire after it and drag playback back to the stale target.
    public mutating func dropBurst() -> [PlayerTouchEffect] {
        burst = nil
        return [.dropPendingSeek, .cancelBurstDismissal]
    }

    /// The burst's self-dismissal ran out.
    public mutating func burstExpired() { burst = nil }

    /// An input to the auto-hide moved. Losing eligibility stops the timer and regaining it
    /// re-arms; playback resuming re-arms only a chrome that shows.
    public func hideTimer(after change: AutoHideInput) -> PlayerTouchEffect? {
        switch change {
        case .pullDragging(let dragging): dragging ? .cancelHide : .rearmHide
        case .menuOpen(let open): open ? .cancelHide : .rearmHide
        case .desiredPlaying(let playing): playing ? (visible ? .rearmHide : nil) : .cancelHide
        }
    }

    /// Leaving `.playing` brings the chrome back over the loading scrim. A failure unmounts the
    /// controls, and their drag, panels and burst die with them, so it also starts the chrome
    /// over: the status bar and home indicator return over the error scrim, pull-to-dismiss
    /// works there, and a retry re-mounts the controls visible and idle.
    public mutating func phaseChanged(from old: PlayerViewModel.Phase, to new: PlayerViewModel.Phase) {
        if case .failed = new {
            self = PlayerTouchChrome()
        } else if old == .playing, new != .playing {
            visible = true
        }
    }

    // MARK: Private

    private static func stepSeconds(_ direction: PlayerSeekDirection) -> Double {
        direction == .forward ? PlayerHUDTuning.clickStepSeconds : -PlayerHUDTuning.clickStepSeconds
    }

    /// One tap of a burst: the same direction extends it (the label accumulates, the dome's clock
    /// holds); a reversal is a fresh burst.
    private mutating func seekStep(_ direction: PlayerSeekDirection, at point: CGPoint,
                                   now: Date) -> [PlayerTouchEffect] {
        let continuing = burst.flatMap { $0.direction == direction ? $0 : nil }
        burst = PlayerSeekBurst(
            direction: direction,
            seconds: (continuing?.seconds ?? 0) + Int(PlayerHUDTuning.clickStepSeconds),
            tapPoint: point,
            trigger: (burst?.trigger ?? 0) + 1,
            burstStart: continuing?.burstStart ?? now,
            lastTap: now
        )
        return [.stepSeek(seconds: Self.stepSeconds(direction)), .rearmBurstDismissal]
    }
}

/// An input the touch chrome's auto-hide depends on.
public enum AutoHideInput: Equatable, Sendable {
    case pullDragging(Bool)
    case menuOpen(Bool)
    case desiredPlaying(Bool)
}

/// What the view runs for the touch chrome, in order.
public enum PlayerTouchEffect: Equatable, Sendable {
    /// Restart the auto-hide, if the chrome is eligible for one.
    case rearmHide
    case cancelHide
    /// Preview one step from the bar's position and debounce the one commit.
    case stepSeek(seconds: Double)
    /// (Re)start the burst's self-dismissal.
    case rearmBurstDismissal
    case cancelBurstDismissal
    /// Drop a queued step commit and the preview it opened.
    case dropPendingSeek
    /// Hold the picture on the preview frame.
    case beginScrubHold
    /// End a drag that has nothing to commit: hand the bar back and let the picture go.
    case cancelScrub
    /// Commit the drag to `fraction`, then report `scrubCommitLanded(generation:)`.
    case commitScrub(generation: Int, fraction: Double)
}
