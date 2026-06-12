import Foundation

public struct SubtitleTrack: Sendable, Hashable {
    public let id: TrackID
    public let displayName: String
    public let languageCode: String?
    public let isForced: Bool
    /// Secondary menu line — what the track is, e.g. "SRT · External" or
    /// "ASS · Embedded" (format · source). Nil when unknown.
    public let detailLabel: String?
    /// A sidecar stream (external file), not muxed into the source container.
    public let isExternal: Bool
    /// Hearing-impaired (SDH) track. Server wiring is deferred; defaults false so
    /// the menu can render the badge once `isHearingImpaired` is plumbed through.
    public let isSDH: Bool

    public init(
        id: TrackID,
        displayName: String,
        languageCode: String?,
        isForced: Bool,
        detailLabel: String? = nil,
        isExternal: Bool = false,
        isSDH: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.languageCode = languageCode
        self.isForced = isForced
        self.detailLabel = detailLabel
        self.isExternal = isExternal
        self.isSDH = isSDH
    }
}
