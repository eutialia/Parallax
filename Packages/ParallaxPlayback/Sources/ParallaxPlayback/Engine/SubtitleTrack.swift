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
    /// An image subtitle (PGS/VobSub) offered on the transcode path: picking it
    /// re-resolves the session with the server burning it into the video (no
    /// client-side overlay — there's no sidecar for an image sub). Costs a full
    /// re-encode and can flip an HDR source to SDR server-side, so the menu marks
    /// it distinctly and the player never auto-selects one as a default.
    public let isBurnedIn: Bool

    public init(
        id: TrackID,
        displayName: String,
        languageCode: String?,
        isForced: Bool,
        detailLabel: String? = nil,
        isExternal: Bool = false,
        isSDH: Bool = false,
        isBurnedIn: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.languageCode = languageCode
        self.isForced = isForced
        self.detailLabel = detailLabel
        self.isExternal = isExternal
        self.isSDH = isSDH
        self.isBurnedIn = isBurnedIn
    }
}
