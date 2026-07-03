import Foundation
import ParallaxCore
import ParallaxJellyfin
import ParallaxFileBrowse
import ParallaxPlayback
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
    /// (i.e. it wasn't minted by `SMBFileSource.itemID(share:path:)`).
    func resolve(_ item: Item, ref: SMBServerRef) async throws -> SMBPlaybackItem {
        // Decode the share path, read the Keychain password, build the credential-free smb:// URL
        // + libVLC credential options — one assembly site shared with the thumbnail provider.
        let ctx = try await SMBSourceResolver.context(for: item, ref: ref, keychain: keychain)

        // Resolve sidecar subtitles (best-effort — failures don't abort playback).
        let subtitleURLs: [Int: URL]
        do {
            let (directory, filename) = splitPath(ctx.path)
            let lister = makeLister(ref, ctx.password)
            let resolver = SMBSubtitleResolver(lister: lister, host: ref.data.host, share: ctx.share, root: "")
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

        // Probe the container so AVKit-decodable files can ride the HTTP bridge
        // (HDR display-match + AirPlay + real buffered ranges). Best-effort with a
        // hard deadline: a hung share must not stall the loading veil — on timeout
        // or error we fall back to today's smb://+VLC route, which needs no probe.
        let reader = SMBRandomAccessReader(host: ref.data.host, username: ref.data.username,
                                           password: ctx.password, domain: ref.data.domain,
                                           share: ctx.share, path: ctx.path)
        let probeResult: MediaProbeResult? = try? await withThrowingTaskGroup(of: MediaProbeResult.self) { group in
            group.addTask { try await MediaProbe.probe(reader) }
            group.addTask { try await Task.sleep(for: .seconds(4)); throw CancellationError() }
            defer { group.cancelAll() }
            return try await group.next()
        }

        let (hints, useBridge) = Self.route(probe: probeResult, sizeBytes: item.sizeBytes)

        if useBridge {
            // The reader is handed to the bridge and owned by it from here — the cleanup
            // closure (Task 5) is the only site that disconnects it.
            let fileName = (ctx.path as NSString).lastPathComponent
            let contentType = hints.container == .mov ? "video/quicktime" : "video/mp4"
            let bridge = SMBHTTPBridge(reader: reader, fileName: fileName, contentType: contentType)
            let url: URL
            do {
                url = try await bridge.start()
            } catch {
                // The bridge never came up, so nothing else will ever tear it down (no
                // SMBPlaybackItem, no cleanup closure) — release its reader here.
                await bridge.stop()
                await reader.disconnect()
                throw error
            }
            return SMBPlaybackItem(
                url: url,
                title: item.displayTitle,
                vlcOptions: [],                        // AVKit path: no VLC credentials in play
                startTime: nil,
                subtitleURLs: subtitleURLs,
                fileSizeBytes: item.sizeBytes,
                hints: hints,
                cleanup: { await bridge.stop(); await reader.disconnect() }
            )
        }

        // VLC route — release the probe's SMB connection (libVLC opens its own) and carry
        // whatever the probe learned so the engine can size its cache; scheme stays smb.
        await reader.disconnect()
        return SMBPlaybackItem(
            url: ctx.url,
            title: item.displayTitle,
            vlcOptions: ctx.vlcOptions,
            startTime: nil,
            subtitleURLs: subtitleURLs,
            fileSizeBytes: item.sizeBytes,
            hints: hints,
            cleanup: nil
        )
    }

    /// Pure routing decision shared by `resolve` and its unit tests. Given the probe
    /// outcome (`nil` = probe failed/timed out) and the file size, decides whether an
    /// AVKit-decodable file may ride the HTTP bridge and builds the matching `PlaybackHints`.
    ///
    /// Bridge ONLY when: the probe ran, the file is complete (an incomplete download needs
    /// VLC + the read-rate duration estimate), no track was codec-`.unknown` (unknown → VLC
    /// keeps it decodable), and the selector's verdict on the `http` candidate hints is AVKit.
    static func route(probe: MediaProbeResult?, sizeBytes: Int64?) -> (hints: PlaybackHints, useBridge: Bool) {
        let candidateHints = PlaybackHints(
            scheme: "http",
            container: probe?.container,
            videoCodec: probe?.videoCodec.knownValue,
            audioCodec: probe?.audioCodec.knownValue,
            subtitleFormats: [],
            fileSizeBytes: sizeBytes
        )
        let bridgeEligible = probe.map {
            $0.isComplete
                && $0.videoCodec != .unknown && $0.audioCodec != .unknown
                && EngineSelector.select(hints: candidateHints) == .avKit
        } ?? false

        if bridgeEligible {
            return (candidateHints, true)
        }
        return (
            PlaybackHints(
                scheme: "smb",
                container: probe?.container,
                videoCodec: probe?.videoCodec.knownValue,
                audioCodec: probe?.audioCodec.knownValue,
                subtitleFormats: [],
                fileSizeBytes: sizeBytes
            ),
            false
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
