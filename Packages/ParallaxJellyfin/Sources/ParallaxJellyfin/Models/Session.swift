import Foundation

public struct Session: Sendable, Hashable, Identifiable {
    public let persisted: PersistedSession
    public let accessToken: String

    public init(persisted: PersistedSession, accessToken: String) {
        self.persisted = persisted
        self.accessToken = accessToken
    }

    public var id: ServerID { persisted.id }
    public var serverURL: URL { persisted.serverURL }
    public var serverName: String { persisted.serverName }
    public var user: UserSnapshot { persisted.user }
}
