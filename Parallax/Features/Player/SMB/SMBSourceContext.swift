import Foundation
import ParallaxCore
import ParallaxJellyfin
import ParallaxFileBrowse

/// The credential-free connection facts for one browsed SMB item: the share it lives on, the
/// share-relative path, the `smb://` URL libVLC opens directly, the libVLC credential options,
/// and the raw password.
///
/// `password` and `vlcOptions` both carry the secret (the options embed `:smb-pwd=…`). This is a
/// transient assembly result — NEVER logged or written anywhere. It exists so the playback
/// resolver and the thumbnail provider build SMB credentials at exactly one site.
struct SMBSourceContext: Sendable {
    /// The share the item lives on, decoded from its `ItemID` (the server can host many shares).
    /// Callers that open their own SMB connection (the subtitle lister) need it to build URLs.
    let share: String
    /// Share-relative path, e.g. `"Movies/Film.mkv"`.
    let path: String
    /// `smb://host/share/path` — credentials are NEVER embedded (they ride `vlcOptions`).
    let url: URL
    /// The Keychain password, for callers that open their own SMB connection (the subtitle lister).
    let password: String
    /// Verbatim libVLC media options carrying the credentials (`:smb-user=…`, `:smb-pwd=…`,
    /// `:smb-domain=…`). Passed straight to playback / the thumbnailer; never logged.
    let vlcOptions: [String]
}

/// Assembles an `SMBSourceContext` from a browsed `Item` + its owning server.
///
/// Mirrors the first four steps every SMB consumer needs: decode the share + share-relative path
/// back out of the `ItemID`, read the password from the Keychain (slot `token-<id>`), build the
/// encoded credential-free URL, and derive the libVLC credential options. Shared by `SMBPlaybackResolver`
/// (playback) and `MediaArtworkProvider` (thumbnails) so credential assembly lives in one place.
enum SMBSourceResolver {
    /// The share + share-relative path encoded in the item's ID — decoded with NO Keychain read, so
    /// a caller can build a cache key and check caches before paying for credential assembly. Returns
    /// nil if the ItemID wasn't minted by `SMBFileSource` (no colon / empty share or path).
    static func shareAndPath(for item: Item) -> (share: String, path: String)? {
        SMBFileSource.decodeItemID(item.id)
    }

    /// - Throws: `AppError.source(.notFound)` if the `ItemID` wasn't minted by `SMBFileSource`, or
    ///   the components can't form a URL.
    static func context(
        for item: Item,
        ref: SMBServerRef,
        keychain: any KeychainStoring
    ) async throws -> SMBSourceContext {
        // The share rides in the ItemID (the server can host many shares), so derive it here
        // rather than from `ref` — `SMBServerRef` no longer carries a single share/root.
        guard let (share, path) = SMBFileSource.decodeItemID(item.id) else {
            throw AppError.source(.notFound)
        }
        let passwordKey = KeychainKey<String>(account: ServerStore.tokenAccount(for: ref.id))
        let password = (try? await keychain.read(passwordKey)) ?? ""
        guard let url = SMBURL.make(host: ref.data.host, share: share, path: path) else {
            throw AppError.source(.notFound)
        }
        let vlcOptions = ref.data.vlcCredentialOptions(password: password)
        return SMBSourceContext(share: share, path: path, url: url, password: password, vlcOptions: vlcOptions)
    }
}
