import Foundation

/// The HUD's track panels.
nonisolated public enum PlayerTrackMenuKind: Hashable, Sendable {
    case audio, subtitles, speed, chapters

    /// VoiceOver name for the open panel. The panel has no header row, so its container carries
    /// the menu's name instead — the opening chip is disabled (hence hidden from VoiceOver) while
    /// the panel is up.
    public var accessibilityTitle: String {
        switch self {
        case .audio: "Audio"
        case .subtitles: "Subtitles"
        case .speed: "Playback speed"
        case .chapters: "Chapters"
        }
    }
}

/// An open panel: which menu, and WHICH OPEN of it. Kind alone is stable across a close/reopen,
/// which is exactly the case that has to produce a new view, so every value mints a fresh token —
/// construction IS the generation bump, with no counter a caller can forget to advance.
nonisolated public struct PlayerPanel: Hashable, Sendable {
    public let kind: PlayerTrackMenuKind
    private let token = UUID()

    public init(kind: PlayerTrackMenuKind) { self.kind = kind }
}

/// What the user is doing inside the mounted HUD: an open track panel, the debug sheet, a finger
/// on the scrub bar. One owner — the player surface — so the facts the surface reads (status bar,
/// pull-to-dismiss, the idle timer) and the facts the controls draw from are the same storage.
/// The controls die with their gestures and panels; whoever unmounts them owns resetting this.
public struct PlayerHUDInteraction: Equatable, Sendable {
    public var panel: PlayerPanel?
    public var debugOpen = false
    /// A finger is on the touch scrub bar: the chrome collapses into the lone bar over a held
    /// frame. Never set by the remote, whose scrubs are `PlayerHUDState.swipeScrub`.
    public var dragScrubbing = false

    public init() {}

    /// A panel or the debug sheet owns the screen.
    public var menuOpen: Bool { panel != nil || debugOpen }
}
