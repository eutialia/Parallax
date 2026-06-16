import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import VLCKitSPM

/// Source-agnostic still-frame thumbnailer backed by VLCKit's `VLCMediaThumbnailer`.
/// Decodes one frame from a video `URL` (local file or `smb://`) and returns it as
/// PNG `Data` — `Sendable`, so the result crosses the package→app boundary cleanly
/// without exposing a non-`Sendable` `CGImage`/`UIImage`.
///
/// **Concurrency:** `VLCMedia`/`VLCMediaThumbnailer` are non-`Sendable`; like
/// `VLCKitEngine`, all VLC work is pinned to `@MainActor`. `VLCMediaThumbnailer`
/// delivers its delegate callbacks on the run loop of the thread that called
/// `fetchThumbnail()` (via KVO + an `NSTimer` — NOT through VLCKit's event
/// dispatcher), and that call is made from `@MainActor`, so the callbacks land on
/// the main run loop. The `nonisolated` `NSObject` delegate methods therefore assert
/// main isolation via `MainActor.assumeIsolated`. (`configureVLCEvents()` is still
/// invoked for global events-config consistency with the engine; it does NOT govern
/// thumbnailer callback threading — the `@MainActor` call site does.)
///
/// **Credentials:** `options` are applied verbatim via `media.addOption(_:)` and are
/// NEVER logged — neither are they, nor the URL, written anywhere. The thumbnailer is
/// option-agnostic; it does not know some options carry credentials (`:smb-user=…`).
///
/// **Aspect behavior (observed on vlckit-spm 4.0.0-alpha.19):** `width: 0, height: 320`
/// makes libvlc derive the width from the source aspect ratio rather than stretching to
/// a fixed box — a 160×90 (16:9) source yields a 569×320 thumbnail (1.778, exactly 16:9),
/// NOT a 320×240 4:3 frame. `width: 0` is honored, so the API defaults to it. (Downstream
/// `MediaImage` fill+crop would absorb a minor mismatch regardless.)
/// A generated still frame plus the source's duration, read off the same `VLCMedia` the
/// thumbnailer already had to parse. `Sendable` so it crosses the package→app boundary cleanly
/// (a raw `CGImage`/`VLCMedia` would not). `duration` is nil when libvlc couldn't determine the
/// length — the caller falls back (e.g. to file size for an SMB tile).
public struct VLCThumbnailFrame: Sendable {
    public let data: Data
    public let duration: Duration?

    public init(data: Data, duration: Duration?) {
        self.data = data
        self.duration = duration
    }
}

@MainActor
public final class VLCThumbnailer {

    public init() {}

    /// One in-flight fetch's strong references. `VLCMediaThumbnailer.delegate` is `weak`,
    /// so BOTH the thumbnailer and its delegate must be retained for the whole fetch or
    /// they deallocate mid-flight and no callback ever arrives.
    private struct Fetch {
        let thumbnailer: VLCMediaThumbnailer
        let delegate: ThumbnailDelegate
    }

    /// Keyed by a per-fetch id so concurrent calls don't clobber each other's refs.
    private var inFlight: [UUID: Fetch] = [:]

    /// Generates a still frame from `url`, returned as PNG data.
    /// - Parameters:
    ///   - url: local file or `smb://` URL to thumbnail.
    ///   - options: pre-built VLC media option strings (e.g. credential options for
    ///     `smb://`, like `":smb-user=alice"`). Applied verbatim; never logged.
    ///   - width: target width; `0` lets libvlc derive it from the source aspect (default).
    ///   - height: target height (default 320).
    ///   - position: 0–1 fraction of the video duration to snapshot (default 0.3).
    ///   - timeout: hard ceiling; if VLC neither finishes nor times out by then, throws `.timedOut`.
    /// - Returns: the PNG frame plus the source duration (nil if libvlc couldn't read the length).
    public func thumbnailData(
        for url: URL,
        options: [String] = [],
        width: CGFloat = 0,
        height: CGFloat = 320,
        position: Float = 0.3,
        timeout: Duration = .seconds(20)
    ) async throws -> VLCThumbnailFrame {
        // Global events-config consistency with the engine (idempotent). Does NOT
        // affect thumbnailer callback threading — see the type doc.
        VLCKitEngine.configureVLCEvents()

        guard let media = VLCMedia(url: url) else {
            throw VLCThumbnailError.mediaRejected
        }
        // Buffer headroom for smb:// (match the engine's value); caller options follow,
        // applied verbatim. Order is irrelevant — libvlc merges per-media options.
        media.addOption(":network-caching=3000")
        for option in options {
            media.addOption(option)
        }

        let id = UUID()
        let cgImage: CGImage = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let delegate = ThumbnailDelegate(
                    continuation: continuation,
                    resolve: { [weak self] result in
                        // Delegate callbacks ride the fetchThumbnail() caller's run loop = main; assert it.
                        MainActor.assumeIsolated {
                            self?.resolve(id, with: result)
                        }
                    }
                )
                let thumbnailer = VLCMediaThumbnailer(media: media, andDelegate: delegate)
                thumbnailer.thumbnailWidth = width
                thumbnailer.thumbnailHeight = height
                thumbnailer.snapshotPosition = position

                // Retain BOTH for the whole fetch (delegate is weak on the thumbnailer).
                inFlight[id] = Fetch(thumbnailer: thumbnailer, delegate: delegate)

                // Hard timeout: races the delegate. Whichever resolves first wins;
                // `resolve` is resume-once (it removes the fetch), so the loser is a no-op.
                delegate.timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.resolve(id, with: .failure(.timedOut))
                }

                thumbnailer.fetchThumbnail()
            }
        } onCancel: {
            // Task cancellation (e.g. a cancelled enclosing tile load) also resolves —
            // otherwise the continuation would never resume. Hop to main since the
            // cancellation handler is nonisolated; resume-once makes a late delegate
            // callback a no-op.
            Task { @MainActor [weak self] in
                self?.resolve(id, with: .failure(.timedOut))
            }
        }

        let data = try Self.encodePNG(cgImage)
        // `media.length` is populated as a side effect of the parse+seek the thumbnailer just
        // performed (positional snapshotting can't seek to 5% without knowing the duration), so
        // it's read here — after a successful frame — without a second parse. nil/0 means libvlc
        // never resolved it; the caller falls back rather than showing a bogus 0.
        let duration = Self.duration(of: media)
        return VLCThumbnailFrame(data: data, duration: duration)
    }

    /// The media's length as a `Duration`, or nil if libvlc hasn't resolved it (`length.value`
    /// is `nil`) or it's non-positive. `VLCTime.value` is milliseconds.
    private static func duration(of media: VLCMedia) -> Duration? {
        guard let milliseconds = media.length.value?.int64Value, milliseconds > 0 else { return nil }
        return .milliseconds(milliseconds)
    }

    /// First resolution wins; later ones (the timeout/delegate/cancel race) are no-ops
    /// because the fetch is already gone. Safe without a lock — everything is `@MainActor`.
    /// Tears down the strong refs + the timeout sleeper, then resumes the continuation it
    /// owns exactly once.
    private func resolve(_ id: UUID, with result: Result<CGImage, VLCThumbnailError>) {
        guard let fetch = inFlight.removeValue(forKey: id) else { return }
        fetch.delegate.timeoutTask?.cancel()
        fetch.delegate.timeoutTask = nil
        fetch.delegate.resolve = nil  // block any late delegate callback
        fetch.delegate.continuation.resume(with: result.mapError { $0 as Error })
    }

    /// Encode a `CGImage` to PNG `Data` via ImageIO. Throws `.encodingFailed` if the
    /// destination can't be created or finalized.
    private static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw VLCThumbnailError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw VLCThumbnailError.encodingFailed
        }
        return data as Data
    }
}

public enum VLCThumbnailError: Error, Sendable {
    case mediaRejected   // VLCMedia(url:) returned nil
    /// VLC's delegate timed out, our hard timeout fired, or the enclosing task was
    /// cancelled. A media that opens but can't decode a frame also surfaces here —
    /// `VLCMediaThumbnailerDelegate` exposes no decode-error callback to distinguish it.
    case timedOut
    case encodingFailed  // CGImage → PNG data failed
}

// MARK: - Delegate

/// Bridges `VLCMediaThumbnailer`'s required delegate callbacks to a one-shot result
/// closure. An `NSObject` because the protocol is Objective-C; `@MainActor`-isolated
/// because its state and the thumbnailer it serves are MainActor-owned. The protocol
/// methods are `nonisolated` (the Obj-C protocol declares no isolation) and hop back to
/// the delegate's own isolation via `assumeIsolated` — valid because `VLCMediaThumbnailer`
/// invokes them on the `fetchThumbnail()` caller's run loop, which is the MainActor. Same
/// shape as `VLCKitEngine`'s `VLCMediaPlayerDelegate` conformance.
@MainActor
private final class ThumbnailDelegate: NSObject, VLCMediaThumbnailerDelegate {

    /// The continuation this fetch owns; resumed exactly once by `VLCThumbnailer.resolve`.
    let continuation: CheckedContinuation<CGImage, Error>

    /// Routes a delegate outcome to `VLCThumbnailer.resolve`; cleared after the first
    /// resolution so a late callback can't re-enter.
    var resolve: ((Result<CGImage, VLCThumbnailError>) -> Void)?

    /// The hard-timeout sleeper, retained here so `resolve` can cancel it.
    var timeoutTask: Task<Void, Never>?

    init(
        continuation: CheckedContinuation<CGImage, Error>,
        resolve: @escaping (Result<CGImage, VLCThumbnailError>) -> Void
    ) {
        self.continuation = continuation
        self.resolve = resolve
    }

    nonisolated func mediaThumbnailer(_ mediaThumbnailer: VLCMediaThumbnailer, didFinishThumbnail thumbnail: CGImage) {
        // `CGImage` is value-immutable; capture is safe across the (same-queue) hop.
        let image = thumbnail
        MainActor.assumeIsolated {
            resolve?(.success(image))
        }
    }

    nonisolated func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer) {
        MainActor.assumeIsolated {
            resolve?(.failure(.timedOut))
        }
    }
}
