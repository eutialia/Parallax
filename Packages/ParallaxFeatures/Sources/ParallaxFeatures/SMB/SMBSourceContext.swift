import Foundation
import ParallaxCore
import ParallaxJellyfin
import ParallaxFileBrowse

/// The connection facts for one browsed SMB item: the share it lives on, the share-relative
/// path and the password.
///
/// `password` is the secret. This is a transient assembly result, never logged or written
/// anywhere. It exists so the playback resolver and the thumbnail provider build SMB
/// credentials at exactly one site.
struct SMBSourceContext: Sendable {
    /// The share the item lives on, decoded from its `ItemID` (the server can host many shares).
    /// Callers that open their own SMB connection (the subtitle lister) need it to build URLs.
    let share: String
    /// Share-relative path, e.g. `"Movies/Film.mkv"`.
    let path: String
    /// The Keychain password, for callers that open their own SMB connection (the subtitle lister).
    let password: String

    /// The pool target for this item's share, signed in as `ref`.
    nonisolated func target(_ ref: SMBServerRef) -> SMBConnectionTarget {
        SMBConnectionTarget(credentials: ref.credentials(password: password), share: share)
    }
}

/// Assembles an `SMBSourceContext` from a browsed `Item` + its owning server.
///
/// Decodes the share and share-relative path back out of the `ItemID` and reads the password
/// from the Keychain (slot `token-<id>`). Shared by `SMBPlaybackResolver` (playback) and
/// `MediaArtworkProvider` (thumbnails) so credential assembly lives in one place.
enum SMBSourceResolver {
    /// The share + share-relative path encoded in the item's ID — decoded with NO Keychain read, so
    /// a caller can build a cache key and check caches before paying for credential assembly. Returns
    /// nil if the ItemID wasn't minted by `SMBFileSource` (no colon / empty share or path).
    ///
    /// `nonisolated` because it is pure: the app target's default `@MainActor` inference would
    /// otherwise put a main-actor hop between the thumbnail actor and its own cache key.
    nonisolated static func shareAndPath(for item: Item) -> (share: String, path: String)? {
        SMBFileSource.decodeItemID(item.id)
    }

    /// - Throws: `AppError.source(.notFound)` if the `ItemID` wasn't minted by `SMBFileSource`;
    ///   `AppError.auth(.credentialUnavailable)` if the saved password's Keychain slot is lost —
    ///   never degraded into an empty-password connection.
    static func context(
        for item: Item,
        ref: SMBServerRef,
        serverStore: ServerStore
    ) async throws -> SMBSourceContext {
        // The share rides in the ItemID (the server can host many shares), so derive it here
        // rather than from `ref` — `SMBServerRef` no longer carries a single share/root.
        guard let (share, path) = SMBFileSource.decodeItemID(item.id) else {
            throw AppError.source(.notFound)
        }
        let password = try await serverStore.smbPassword(for: ref.id)
        return SMBSourceContext(share: share, path: path, password: password)
    }
}
