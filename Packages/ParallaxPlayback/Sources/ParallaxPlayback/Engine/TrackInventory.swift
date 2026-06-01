import Foundation

public struct TrackInventory: Sendable, Hashable {
    public let audio: [AudioTrack]
    public let subtitles: [SubtitleTrack]
    /// The track each list is *currently* playing, as chosen by the engine's
    /// default selection. Lets the UI show a checkmark on the active track at
    /// start instead of an unselected menu. `nil` subtitle id means "Off".
    public let selectedAudioID: TrackID?
    public let selectedSubtitleID: TrackID?

    public init(
        audio: [AudioTrack],
        subtitles: [SubtitleTrack],
        selectedAudioID: TrackID? = nil,
        selectedSubtitleID: TrackID? = nil
    ) {
        self.audio = audio
        self.subtitles = subtitles
        self.selectedAudioID = selectedAudioID
        self.selectedSubtitleID = selectedSubtitleID
    }

    public static let empty = TrackInventory(audio: [], subtitles: [])
}
