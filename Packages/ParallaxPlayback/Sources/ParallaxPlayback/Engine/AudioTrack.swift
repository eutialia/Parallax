import Foundation

public struct AudioTrack: Sendable, Hashable {
    public let id: String
    public let displayName: String
    public let languageCode: String?

    public init(id: String, displayName: String, languageCode: String?) {
        self.id = id
        self.displayName = displayName
        self.languageCode = languageCode
    }
}
