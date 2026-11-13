import Foundation
import ParallaxCore
import ParallaxJellyfin
import ParallaxFileBrowse
import ParallaxPlayback
import OSLog

private let logger = Logger(subsystem: "Parallax", category: "SMBPlaybackResolver")

/// Turns a browsed SMB `Item` into a ready-to-play `SMBPlaybackItem`: decodes the `ItemID` back
/// into a share path, reads the password from the Keychain, matches sidecar subtitles and
/// starts the local server AVPlayer reads the file through. A subtitle failure is not fatal;
/// the video plays without them.
public struct SMBPlaybackResolver {
    let serverStore: ServerStore
    /// The app's one connection pool. The sidecar-subtitle lister, the container probe and the
    /// sidecar-subtitle fetch all borrow from it instead of standing up a fresh SMB session per
    /// resolve.
    let connections: SMBConnections
    let resumeStore: SMBResumeStore
    /// The delivery's probe deadline sleeps on it.
    let clock: any Clock<Duration>
    /// Its `avPlayer` support decides which probed files AVPlayer can read as they are.
    let deviceProfileBuilder: DeviceProfileBuilder

    /// Throws `AppError.source(.notFound)` if the `ItemID` wasn't minted by
    /// `SMBFileSource.itemID(share:path:)`, the `Unplayable` reason's `AppError` when AVPlayer
    /// cannot play the file, and the read failure's `AppError` when the file could not be probed.
    public func resolve(_ item: Item, ref: SMBServerRef) async throws -> SMBPlaybackItem {
        let ctx = try await SMBSourceResolver.context(for: item, ref: ref, serverStore: serverStore)

        let subtitleURLs: [Int: URL]
        let subtitleLabels: [Int: String]
        do {
            let (directory, filename) = splitPath(ctx.path)
            let lister = connections.lister(ref.credentials(password: ctx.password))
            let resolver = SMBSubtitleResolver(lister: lister, host: ref.data.host, share: ctx.share, root: "")
            let matches = try await resolver.subtitles(for: filename, in: directory)
            // Label, then filename: loosened matching can emit colliding labels (several
            // "Default" subs), and a label-only sort would leave the index-to-URL map depending
            // on the lister's enumeration order.
            let sorted = matches.sorted {
                ($0.label, $0.url.lastPathComponent) < ($1.label, $1.url.lastPathComponent)
            }
            subtitleURLs = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($0.offset, $0.element.url) })
            subtitleLabels = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($0.offset, $0.element.label) })
        } catch {
            logger.warning("SMB subtitle resolution failed for \(ctx.path, privacy: .public): \(error, privacy: .public)")
            subtitleURLs = [:]
            subtitleLabels = [:]
        }

        let device = await deviceProfileBuilder.build()
        let delivery: SMBDelivery
        do {
            delivery = try await SMBDelivery.start(
                reader: connections.reader(ctx.target(ref), ctx.path),
                fileName: (ctx.path as NSString).lastPathComponent,
                support: device.avPlayer, showsHDR: !device.hdr.isEmpty, clock: clock)
        } catch let reason as Unplayable {
            logger.notice("SMB file unplayable: \(String(describing: reason), privacy: .public) for \(ctx.path, privacy: .public)")
            throw reason.appError
        } catch SMBDelivery.ProbeFailure.timedOut(let transportFault) {
            logger.warning("SMB probe timed out for \(ctx.path, privacy: .public) transportFault=\(transportFault)")
            throw AppError.source(.connectionLost)
        } catch SMBDelivery.ProbeFailure.unreadable(let underlying, _) {
            throw SMBFileSource.mapReadError(underlying, share: ctx.share, path: ctx.path)
        }

        // No server holds SMB progress, so the offset comes from the on-device store.
        let startTime = await resumeStore.resumeTime(for: item.id)

        return SMBPlaybackItem(
            itemID: item.id,
            url: delivery.url,
            title: item.displayTitle,
            startTime: startTime,
            subtitleURLs: subtitleURLs,
            subtitleLabels: subtitleLabels,
            cleanup: { await delivery.stop(discardingConnection: true) }
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
    public func subtitleData(for url: URL, ref: SMBServerRef) async -> Data? {
        guard let (_, share, path) = SMBURL.parse(url) else {
            logger.warning("SMB subtitle URL not decodable")
            return nil
        }
        guard let password = try? await serverStore.smbPassword(for: ref.id) else {
            logger.warning("SMB subtitle skipped — saved password unavailable")
            return nil
        }
        let reader = connections.reader(SMBConnectionTarget(credentials: ref.credentials(password: password), share: share), path)
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

extension Unplayable {
    nonisolated var appError: AppError {
        switch self {
        case .incompleteFile: .playback(.incompleteFile)
        case .container, .videoCodec, .audioCodec, .directHazards, .refused:
            .playback(.unsupportedFormat(reason: "\(self)"))
        }
    }
}
