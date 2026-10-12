import ParallaxFileBrowse
import ParallaxJellyfin

/// Identity + connection metadata for a configured SMB source. Mirrors how
/// `.jellyfin(Session)` carries everything a Jellyfin source needs — minus the
/// password, which is read from the Keychain (slot `token-<id>`) at connect time.
public nonisolated struct SMBServerRef: Hashable, Sendable {
    public let id: ServerID
    public let data: SMBServerData

    public init(id: ServerID, data: SMBServerData) {
        self.id = id
        self.data = data
    }

    /// This server's stored identity plus the Keychain password, as the one value every SMB
    /// connection-builder takes. ONE place joins the two halves, so no call site can transpose the
    /// interchangeable credential strings on its way to a lister, a reader, or a pool key.
    public func credentials(password: String) -> SMBCredentials {
        SMBCredentials(
            host: data.host, username: data.username, password: password, domain: data.domain
        )
    }
}
