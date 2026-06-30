import Observation

/// Whether the subtitle-preview "lights" overlay is showing. The Subtitles menu (a normal pushed
/// screen) flips this on/off as it appears/disappears; the app root watches it and fades the
/// floating `SubtitleStageLights` in over everything. Decoupled from the menu so only the subtitle
/// + lights float on top — the menu itself slides in as usual.
@MainActor
@Observable
final class SubtitlePreviewState {
    private(set) var isActive = false

    func activate() { isActive = true }
    func deactivate() { isActive = false }
}
