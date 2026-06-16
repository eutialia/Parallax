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
        // Decode the share path, read the Keychain password, build the credential-free smb:// URL
        // + libVLC credential options — one assembly site shared with the thumbnail provider.
        let ctx = try await SMBSourceResolver.context(for: item, ref: ref, keychain: keychain)

        // Resolve sidecar subtitles (best-effort — failures don't abort playback).
        let subtitleURLs: [Int: URL]
        do {
            let (directory, filename) = splitPath(ctx.path)
            let lister = makeLister(ref, ctx.password)
            let resolver = SMBSubtitleResolver(lister: lister, host: ref.data.host, share: ref.data.share, root: "")
            let matches = try await resolver.subtitles(for: filename, in: directory)
            // Sort by label, then filename, for deterministic index assignment. The filename
            // tie-break matters: loosened matching can emit colliding labels (e.g. several "Default"
            // lonely-video subs), and a label-only sort isn't stable — the index→URL map would
            // otherwise depend on the lister's enumeration order.
            let sorted = matches.sorted {
                ($0.label, $0.url.lastPathComponent) < ($1.label, $1.url.lastPathComponent)
            }
            subtitleURLs = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($0.offset, $0.element.url) })
        } catch {
            logger.warning("SMB subtitle resolution failed for \(ctx.path, privacy: .public): \(error, privacy: .public)")
            subtitleURLs = [:]
        }

        return SMBPlaybackItem(
            url: ctx.url,
            title: item.displayTitle,
            vlcOptions: ctx.vlcOptions,
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
