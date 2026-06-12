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
}
