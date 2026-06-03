import Foundation

public struct SubtitleTrack: Sendable, Hashable {
    public let id: TrackID
    public let displayName: String
    public let languageCode: String?
    public let isForced: Bool
    /// "Embedded" (muxed) or "External" (sidecar file). Nil when unknown.
    public let sourceLabel: String?
    /// Subtitle format badge, e.g. "SRT" / "PGS" / "ASS". Nil when unknown.
    public let formatLabel: String?
    /// Hearing-impaired (SDH) track. Server wiring is deferred; defaults false so
    /// the menu can render the badge once `isHearingImpaired` is plumbed through.
    public let isSDH: Bool

    public init(
        id: TrackID,
        displayName: String,
        languageCode: String?,
        isForced: Bool,
        sourceLabel: String? = nil,
        formatLabel: String? = nil,
        isSDH: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.languageCode = languageCode
        self.isForced = isForced
        self.sourceLabel = sourceLabel
        self.formatLabel = formatLabel
        self.isSDH = isSDH
    }
}
