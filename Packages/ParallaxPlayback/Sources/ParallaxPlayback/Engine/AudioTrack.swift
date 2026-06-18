import Foundation

public struct AudioTrack: Sendable, Hashable {
    public let id: TrackID
    public let displayName: String
    public let languageCode: String?
    /// Secondary menu line — what the track is made of, e.g. "TrueHD · 7.1"
    /// (codec · channel layout). Nil when the source path (engine inventory on
    /// direct-play without server metadata) doesn't expose codec detail.
    public let detailLabel: String?
    /// Whether this track is delivered re-encoded on the current device (transcode
    /// path, source codec not in the copy set). False = delivered as-is ("Direct Play").
    public let isTranscode: Bool
    /// The delivered codec when transcoding, e.g. "AAC". Nil when not transcoding.
    public let transcodeTarget: String?

    public init(
        id: TrackID,
        displayName: String,
        languageCode: String?,
        detailLabel: String? = nil,
        isTranscode: Bool = false,
        transcodeTarget: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.languageCode = languageCode
        self.detailLabel = detailLabel
        self.isTranscode = isTranscode
        self.transcodeTarget = transcodeTarget
    }

    /// Channel layout only ("7.1"), pulled from `detailLabel`'s "codec · channels" so
    /// the player's audio chip can read "English 7.1" — channels without the codec the
    /// menu detail line already carries. Nil when detail is absent (VLC inventory /
    /// direct-play) or codec-only, so the chip falls back to the language name alone.
    public var channelLabel: String? {
        guard let detailLabel else { return nil }
        let parts = detailLabel.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, let channels = parts.last, !channels.isEmpty else { return nil }
        return channels
    }
}
