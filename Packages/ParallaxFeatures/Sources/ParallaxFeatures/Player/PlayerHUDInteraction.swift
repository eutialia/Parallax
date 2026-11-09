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

/// The menus open inside the mounted HUD: a track panel or the debug sheet. One owner — the
/// player surface — so the facts the surface reads (pull-to-dismiss, the idle timer) and the
/// facts the controls draw from are the same storage. The panels die with the controls; whoever
/// unmounts them owns resetting this.
public struct PlayerHUDInteraction: Equatable, Sendable {
    public var panel: PlayerPanel?
    public var debugOpen = false

    public init() {}

    /// A panel or the debug sheet owns the screen.
    public var menuOpen: Bool { panel != nil || debugOpen }
}
