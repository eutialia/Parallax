import Observation

/// The one-shot rule for the contextual Skip / Next Episode button. The button shows while the
/// playhead sits in an actionable segment and the surface allows it, for one countdown; once it
/// has shown — the countdown ran out, the user fired it, or the tvOS remote revealed past it —
/// it stays down for that segment until the playhead leaves it, so a re-entry re-arms it. Shared by the touch tap and the tvOS remote, so both honour the same one-shot.
@Observable
public final class SegmentPromptGate {
    /// How long the button shows before it dismisses itself — the length of its drain.
    public static let countdown: Duration = .seconds(5)

    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let activeSegmentID: () -> String?
    private var expiredID: String?

    init(clock: any Clock<Duration>, activeSegmentID: @escaping () -> String?) {
        self.clock = clock
        self.activeSegmentID = activeSegmentID
    }

    /// The segment whose button is on screen, or nil. `enabled` is the surface's say: the tvOS
    /// floor only, and not under a touch drag-scrub's lone bar.
    public func shownSegmentID(enabled: Bool) -> String? {
        guard enabled, let id = activeSegmentID(), id != expiredID else { return nil }
        return id
    }

    public func promptVisible(enabled: Bool) -> Bool { shownSegmentID(enabled: enabled) != nil }

    /// Dismiss the active segment's button for the rest of this visit to it.
    public func expirePrompt() { expiredID = activeSegmentID() }

    /// Every position the player publishes, in any phase. The playhead leaving the dismissed
    /// segment re-arms the one-shot; a reload that lands back inside it does not.
    func playheadMoved(toSegment id: String?) {
        if expiredID != nil, id != expiredID { expiredID = nil }
    }

    /// The shown button's countdown, on the player's clock. Run it for as long as the button
    /// shows; it expires the button when the countdown runs out, and does nothing if cancelled.
    public func runCountdown() async {
        do { try await clock.sleep(for: Self.countdown) } catch { return }
        guard !Task.isCancelled else { return }
        expirePrompt()
    }
}
