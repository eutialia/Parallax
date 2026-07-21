import Foundation
import ParallaxCore
import ParallaxJellyfin
import ParallaxFileBrowse
import ParallaxPlayback
import OSLog
import Synchronization

private let logger = Logger(subsystem: "Parallax", category: "SMBPlaybackResolver")

/// Turns a browsed SMB `Item` into a ready-to-play `SMBPlaybackItem`.
///
/// Decodes the `ItemID` back into a share path, reads the password from the Keychain,
/// builds the credential-free `smb://` URL + libVLC credential options, and resolves
/// filename-matched sidecar subtitles. Subtitle resolution failures are non-fatal —
/// the video plays with an empty subtitle map rather than aborting.
struct SMBPlaybackResolver {
    let serverStore: ServerStore
    /// Injectable so subtitle resolution is fakeable in tests; defaults to the live AMSMB2 lister.
    var makeLister: @Sendable (_ ref: SMBServerRef, _ password: String) -> any SMBLister = { ref, password in
        AMSMB2Lister(host: ref.data.host, username: ref.data.username, password: password, domain: ref.data.domain)
    }
    /// Injectable so tests read/write an isolated suite-backed store instead of `UserDefaults.standard`.
    var resumeStore: SMBResumeStore = .shared

    /// Resolves a browsed SMB `Item` into a ready-to-play `SMBPlaybackItem`.
    ///
    /// Throws `AppError.source(.notFound)` if the `ItemID` can't be decoded back to a share path
    /// (i.e. it wasn't minted by `SMBFileSource.itemID(share:path:)`).
    func resolve(_ item: Item, ref: SMBServerRef) async throws -> SMBPlaybackItem {
        // Decode the share path, read the Keychain password, build the credential-free smb:// URL
        // + libVLC credential options — one assembly site shared with the thumbnail provider.
        let ctx = try await SMBSourceResolver.context(for: item, ref: ref, serverStore: serverStore)

        // Resolve sidecar subtitles (best-effort — failures don't abort playback).
        let subtitleURLs: [Int: URL]
        let subtitleLabels: [Int: String]
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
            // Same index keying as the URL map — the label survives so the subtitle menu
            // can name each synthetic external track ("English" etc.) instead of "Track N".
            subtitleLabels = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($0.offset, $0.element.label) })
        } catch {
            logger.warning("SMB subtitle resolution failed for \(ctx.path, privacy: .public): \(error, privacy: .public)")
            subtitleURLs = [:]
            subtitleLabels = [:]
        }

        // Probe the container so AVKit-decodable files can ride the HTTP bridge
        // (HDR display-match + AirPlay + real buffered ranges). Best-effort with a
        // hard deadline: a hung share must not stall the loading veil — on timeout
        // or error we fall back to today's smb://+VLC route, which needs no probe.
        let reader = SMBRandomAccessReader(host: ref.data.host, username: ref.data.username,
                                           password: ctx.password, domain: ref.data.domain,
                                           share: ctx.share, path: ctx.path)
        let probeResult = await Self.probeWithDeadline(reader)

        let (hints, useBridge) = Self.route(probe: probeResult, sizeBytes: item.sizeBytes)

        // Local resume: SMB has no server-side progress store, so the offset comes from
        // the on-device store (nil = fresh start). Same key the VM saves beats under.
        let startTime = await resumeStore.resumeTime(for: item.id)

        if useBridge {
            // The reader is handed to the session and owned by it from here — the cleanup
            // closure is the only site that tears it down. `session.start()` self-tears-down
            // on a start failure (no SMBPlaybackItem, no cleanup closure would ever run).
            let fileName = (ctx.path as NSString).lastPathComponent
            let contentType = hints.container == .mov ? "video/quicktime" : "video/mp4"
            let session = SMBBridgeSession(reader: reader, fileName: fileName, contentType: contentType)
            let url = try await session.start()
            return SMBPlaybackItem(
                itemID: item.id,
                url: url,
                title: item.displayTitle,
                vlcOptions: [],                        // AVKit path: no VLC credentials in play
                startTime: startTime,
                subtitleURLs: subtitleURLs,
                subtitleLabels: subtitleLabels,
                // Bridge route requires a probe-proven complete file (route(probe:sizeBytes:)'s
                // bridgeEligible gate) — AVKit reads the container's own duration atom, no estimate.
                hasTrustworthyDuration: true,
                hints: hints,
                cleanup: { await session.stop() }
            )
        }

        // VLC route — release the probe's SMB connection (libVLC opens its own) and carry
        // whatever the probe learned so the engine can size its cache; scheme stays smb.
        if probeResult == nil {
            // Probe timed out or failed: the reader may be wedged in a native AMSMB2 read
            // that won't return until its socket timeout. Awaiting disconnect() inline would
            // serialize behind that wedge on the reader's actor and re-stall resolve()'s
            // return — the very veil-stall the 4s deadline just avoided. Fire-and-forget:
            // disconnect is best-effort cleanup, and it drains behind the wedged read either
            // way once the native call unwinds.
            Task { await reader.disconnect() }
        } else {
            // Probe completed; the reader is idle — release it inline before returning.
            await reader.disconnect()
        }
        return SMBPlaybackItem(
            itemID: item.id,
            url: ctx.url,
            title: item.displayTitle,
            vlcOptions: ctx.vlcOptions,
            startTime: startTime,
            subtitleURLs: subtitleURLs,
            subtitleLabels: subtitleLabels,
            // VLC route: trustworthy only when the probe ran AND proved the file complete — an
            // unproven/incomplete file may synthesize its duration from the read-rate estimate
            // (VLCKitEngine.effectiveDurationMs), which SMBResumeStore's 95% clear must never trust.
            hasTrustworthyDuration: probeResult?.isComplete == true,
            hints: hints,
            cleanup: nil
        )
    }

    /// Fetches the bytes of an `smb://` sidecar subtitle for the client-side overlay.
    ///
    /// The default `URLSession` `subtitleFetch` can't open `smb://`, so `PlayerView` routes the
    /// SMB scheme here. Decodes the URL back to share + path (`SMBURL.parse`), reads the password
    /// from the same Keychain slot `resolve` uses, opens a short-lived `SMBRandomAccessReader`,
    /// and returns up to 4 MiB (a subtitle file larger than that isn't a subtitle file). Best-effort:
    /// nil on any failure, logged at warning WITHOUT credentials (the path may be logged, matching
    /// the reader's own precedent).
    func subtitleData(for url: URL, ref: SMBServerRef) async -> Data? {
        guard let (_, share, path) = SMBURL.parse(url) else {
            logger.warning("SMB subtitle URL not decodable")
            return nil
        }
        guard let password = try? await serverStore.smbPassword(for: ref.id) else {
            logger.warning("SMB subtitle skipped — saved password unavailable")
            return nil
        }
        let reader = SMBRandomAccessReader(host: ref.data.host, username: ref.data.username,
                                           password: password, domain: ref.data.domain,
                                           share: share, path: path)
        defer { Task { await reader.disconnect() } }
        do {
            let size = try await reader.fileSize
            let capped = Int(min(size, 4 * 1024 * 1024))
            guard capped > 0 else { return nil }
            return try await reader.read(offset: 0, length: capped)
        } catch {
            logger.warning("SMB subtitle read failed for \(path, privacy: .public): \(error, privacy: .public)")
            return nil
        }
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

    /// Races a container probe against a hard `seconds` deadline, abandoning the probe
    /// if the deadline wins. Returns the probe result, or `nil` on timeout/failure —
    /// `route(probe:sizeBytes:)` reads `nil` as "fall back to the VLC route."
    ///
    /// Unstructured on purpose: a task group would await the probe child even after
    /// `cancelAll()`, so a wedged share stalls the loading veil until AMSMB2's own
    /// socket timeout. Racing an abandoned `Task` keeps the deadline promise; the zombie
    /// probe self-terminates within the reader's connect timeout and holds only memory
    /// (the reader outlives it either way — the bridge route hands it to the bridge, the
    /// VLC route fire-and-forget-disconnects it behind the in-flight read).
    static func probeWithDeadline(_ reader: any RandomAccessReading, seconds: Double = 4) async -> MediaProbeResult? {
        await withCheckedContinuation { (continuation: CheckedContinuation<MediaProbeResult?, Never>) in
            let latch = OneShotLatch(continuation)
            let probe = Task { latch.resume(try? await MediaProbe.probe(reader)) }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                probe.cancel()          // cooperative only; the latch already unblocked the caller
                latch.resume(nil)
            }
        }
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

/// Resumes a `CheckedContinuation` exactly once, thread-safe. The probe race has two
/// racers that can each try to complete the continuation (the probe finishing, or the
/// deadline firing); whichever wins takes the continuation out under the lock, and the
/// loser's `resume` is a no-op. A double-resume of a `CheckedContinuation` traps, so the
/// mutual exclusion here is load-bearing, not defensive.
private final class OneShotLatch: Sendable {
    private let box: Mutex<CheckedContinuation<MediaProbeResult?, Never>?>

    init(_ continuation: CheckedContinuation<MediaProbeResult?, Never>) {
        box = Mutex(continuation)
    }

    func resume(_ value: MediaProbeResult?) {
        let continuation = box.withLock { stored -> CheckedContinuation<MediaProbeResult?, Never>? in
            defer { stored = nil }
            return stored
        }
        continuation?.resume(returning: value)
    }
}
