import Foundation

public struct SubtitleTrack: Sendable, Hashable {
    public let id: TrackID
    public let displayName: String
    public let languageCode: String?
    public let isForced: Bool

    public init(id: TrackID, displayName: String, languageCode: String?, isForced: Bool) {
        self.id = id
        self.displayName = displayName
        self.languageCode = languageCode
        self.isForced = isForced
    }
}
