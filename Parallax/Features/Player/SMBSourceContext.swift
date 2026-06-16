import Foundation
import ParallaxCore
import ParallaxJellyfin
import ParallaxFileBrowse

/// The credential-free connection facts for one browsed SMB item: the share-relative path,
/// the `smb://` URL libVLC opens directly, the libVLC credential options, and the raw password.
///
/// `password` and `vlcOptions` both carry the secret (the options embed `:smb-pwd=…`). This is a
/// transient assembly result — NEVER logged or written anywhere. It exists so the playback
/// resolver and the thumbnail provider build SMB credentials at exactly one site.
struct SMBSourceContext: Sendable {
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
/// Mirrors the first four steps every SMB consumer needs: decode the share path back out of the
/// `ItemID`, read the password from the Keychain (slot `token-<id>`), build the encoded
/// credential-free URL, and derive the libVLC credential options. Shared by `SMBPlaybackResolver`
/// (playback) and `MediaArtworkProvider` (thumbnails) so credential assembly lives in one place.
enum SMBSourceResolver {
    /// The share-relative path encoded in the item's ID — decoded with NO Keychain read, so a
    /// caller can build a cache key and check caches before paying for credential assembly.
    /// Returns nil if the ItemID wasn't minted for this share.
    static func sharePath(for item: Item, ref: SMBServerRef) -> String? {
        SMBMediaRepository.playablePath(fromItemID: item.id, share: ref.data.share)
    }

    /// - Throws: `AppError.source(.notFound)` if the `ItemID` wasn't minted for this share, or
    ///   the components can't form a URL.
    static func context(
        for item: Item,
        ref: SMBServerRef,
        keychain: any KeychainStoring
    ) async throws -> SMBSourceContext {
        guard let path = SMBMediaRepository.playablePath(fromItemID: item.id, share: ref.data.share) else {
            throw AppError.source(.notFound)
        }
        let passwordKey = KeychainKey<String>(account: ServerStore.tokenAccount(for: ref.id))
        let password = (try? await keychain.read(passwordKey)) ?? ""
        guard let url = SMBURL.make(host: ref.data.host, share: ref.data.share, path: path) else {
            throw AppError.source(.notFound)
        }
        let vlcOptions = ref.data.vlcCredentialOptions(password: password)
        return SMBSourceContext(path: path, url: url, password: password, vlcOptions: vlcOptions)
    }
}
