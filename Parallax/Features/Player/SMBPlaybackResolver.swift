import Foundation
import ParallaxCore
import ParallaxJellyfin
import ParallaxFileBrowse
import OSLog

private let logger = Logger(subsystem: "Parallax", category: "SMBPlaybackResolver")

/// Turns a browsed SMB `Item` into a ready-to-play `SMBPlaybackItem`.
///
/// Decodes the `ItemID` back into a share path, reads the password from the Keychain,
/// builds the credential-free `smb://` URL + libVLC credential options, and resolves
/// filename-matched sidecar subtitles. Subtitle resolution failures are non-fatal —
/// the video plays with an empty subtitle map rather than aborting.
struct SMBPlaybackResolver {
    let keychain: any KeychainStoring
    /// Injectable so subtitle resolution is fakeable in tests; defaults to the live AMSMB2 lister.
    var makeLister: @Sendable (_ ref: SMBServerRef, _ password: String) -> any SMBLister = { ref, password in
        AMSMB2Lister(host: ref.data.host, username: ref.data.username, password: password, domain: ref.data.domain)
    }

    /// Resolves a browsed SMB `Item` into a ready-to-play `SMBPlaybackItem`.
    ///
    /// Throws `AppError.source(.notFound)` if the `ItemID` can't be decoded back to a share path
    /// (i.e. it wasn't minted by `SMBMediaRepository` for the given server's share).
    func resolve(_ item: Item, ref: SMBServerRef) async throws -> SMBPlaybackItem {
        // 1. Decode the share path from the ItemID.
        guard let path = SMBMediaRepository.playablePath(fromItemID: item.id, share: ref.data.share) else {
            throw AppError.source(.notFound)
        }

        // 2. Read the password from Keychain; fall back to empty string if absent.
        let passwordKey = KeychainKey<String>(account: "token-\(ref.id.rawValue)")
        let password = (try? await keychain.read(passwordKey)) ?? ""

        // 3. Build the credential-free smb:// URL.
        let rawURL = "smb://\(ref.data.host)/\(ref.data.share)/\(path)"
        guard let url = URL(string: rawURL) else {
            throw AppError.source(.notFound)
        }

        // 4. Build the libVLC credential options (password never goes into the URL string).
        let vlcOptions = ref.data.vlcCredentialOptions(password: password)

        // 5. Resolve sidecar subtitles (best-effort — failures don't abort playback).
        let subtitleURLs: [Int: URL]
        do {
            let (directory, filename) = splitPath(path)
            let lister = makeLister(ref, password)
            let resolver = SMBSubtitleResolver(lister: lister, host: ref.data.host, share: ref.data.share, root: "")
            let matches = try await resolver.subtitles(for: filename, in: directory)
            // Sort by label for deterministic index assignment so the map is reproducible.
            let sorted = matches.sorted { $0.label < $1.label }
            subtitleURLs = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($0.offset, $0.element.url) })
        } catch {
            logger.warning("SMB subtitle resolution failed for \(path, privacy: .public): \(error, privacy: .public)")
            subtitleURLs = [:]
        }

        // 6. Return the fully resolved item.
        return SMBPlaybackItem(
            url: url,
            title: item.displayTitle,
            vlcOptions: vlcOptions,
            startTime: nil,
            subtitleURLs: subtitleURLs
        )
    }

    // MARK: - Private helpers

    /// Splits a share-relative path into (directory, filename).
    /// `"Movies/Film.mkv"` → `("Movies", "Film.mkv")`
    /// `"Film.mkv"`        → `("", "Film.mkv")`
    private func splitPath(_ path: String) -> (directory: String, filename: String) {
        guard let slashIndex = path.lastIndex(of: "/") else {
            return ("", path)
        }
        let directory = String(path[path.startIndex..<slashIndex])
        let filename  = String(path[path.index(after: slashIndex)...])
        return (directory, filename)
    }
}
