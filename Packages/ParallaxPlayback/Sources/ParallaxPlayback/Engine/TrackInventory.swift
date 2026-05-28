import Foundation

public struct TrackInventory: Sendable, Hashable {
    public let audio: [AudioTrack]
    public let subtitles: [SubtitleTrack]

    public init(audio: [AudioTrack], subtitles: [SubtitleTrack]) {
        self.audio = audio
        self.subtitles = subtitles
    }

    public static let empty = TrackInventory(audio: [], subtitles: [])
}
