/// The touch player's chrome: whether it shows, and what the user is doing inside it. Owned by
/// the player surface, which derives the system chrome from it and mounts the controls that
/// drive it.
public struct PlayerTouchChrome: Equatable, Sendable {
    public var visible = true
    public var interaction = PlayerHUDInteraction()

    public init() {}

    /// The status bar hides with the chrome, and under a drag-scrub, whose lone bar reads as a
    /// clean screen.
    public var statusBarHidden: Bool { !visible || interaction.dragScrubbing }
    /// The home indicator follows the same rule as the status bar.
    public var systemOverlaysVisible: Bool { !statusBarHidden }
    /// The pull stands down while a panel owns the screen (a drag inside a list must not drag the
    /// player) and while a finger holds the scrub bar.
    public var pullToDismissEnabled: Bool { !interaction.menuOpen && !interaction.dragScrubbing }
    /// The segment button yields the bottom edge to the drag-scrub's lone bar.
    public var segmentPromptEnabled: Bool { !interaction.dragScrubbing }

    /// The controls live only while the stream does. Leaving `.playing` brings the chrome back,
    /// so the status bar and home indicator return over a loading or error scrim and a retry
    /// re-mounts the controls already visible.
    public mutating func phaseChanged(from old: PlayerViewModel.Phase, to new: PlayerViewModel.Phase) {
        if old == .playing, new != .playing { visible = true }
    }
}
