import Foundation
import CoreGraphics
import ImageIO
import ParallaxCore
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
/// **Pre-parse (crash guard):** the media is parsed HERE, under this API's own deadline,
/// and `fetchThumbnail()` is only ever called with `parsedStatus == .done`. VLCKit
/// 4.0.0-alpha.19's `VLCMediaThumbnailer` schedules a 10s `_parsingTimeoutTimer` when handed
/// an unparsed media, and its `mediaParsingTimedOut` path — the one a slow remote share
/// (e.g. SMB over VPN) always hits — never nils the timer ivar, so the thumbnailer's
/// `dealloc` later dies on `NSAssert(!_parsingTimeoutTimer, @"Timer not released")`
/// (`NSInternalInconsistencyException` on a background thread). Upstream rewrote the
/// thumbnailer in alpha.20 (no timers), but vlckit-spm ships nothing newer than alpha.19.
/// A `.done` media skips that entire branch, making the assert unreachable.
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
    ///   - position: 0–1 fraction of the video duration to snapshot (default 0.3). Fractions
    ///     below the 0.3 default are applied as a `:start-time=` media option when the
    ///     pre-parse resolved a duration, so the decode opens at the target offset directly.
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
        // Deliberately NOT the engine's 3000ms: that value sizes a smooth-playback
        // read-ahead, and the input pre-fills it before decode starts, so a frame grab
        // would pay ~3s of stream bytes up front — the dominant per-fetch cost on a
        // high-RTT link (SMB over VPN). A grab needs only a few frames; 500ms cuts
        // time-to-first-frame without starving the decoder. Caller options follow,
        // applied verbatim. Order is irrelevant — libvlc merges per-media options.
        media.addOption(":network-caching=500")
        for option in options {
            media.addOption(option)
        }

        // Pre-parse under our own deadline — see the type doc's "Pre-parse (crash guard)".
        // The parse SHARES `timeout` with the fetch: one ceiling for the whole call, as the
        // call sites (and their negative caches) assume. A non-`.done` outcome (libvlc
        // timeout/failure, our safety net, or task cancellation) fails the fetch here,
        // before the thumbnailer exists.
        let clock = ContinuousClock()
        let parseStart = clock.now
        let parsed = await MediaParseAwaiter().run(media, timeout: timeout)
        guard parsed == .done else { throw VLCThumbnailError.parseTimedOut }
        let remaining = timeout - parseStart.duration(to: clock.now)
        guard remaining > .zero else { throw VLCThumbnailError.parseTimedOut }

        // Early-frame asks (< the 0.3 default) land the internal player AT the snapshot
        // offset instead of opening at 0:00 and seeking: the pre-parse just resolved the
        // duration, so the fraction converts to `:start-time=` and the open's first reads
        // are already the target bytes — one less mid-file seek over the share. The nudge
        // past 0.05 dodges a19's `position <= 0.05 → re-seek to 30%` broken-file heuristic
        // (`didFetchThumbnail`), which would otherwise turn a shallow ask into exactly the
        // deep Matroska seek it exists to avoid. The 0.3 default is excluded because a19
        // sets its own start-time for it (duplicate options); unknown duration falls back
        // to the prior open-at-zero behavior.
        //
        // snapshotPosition MUST get the same nudged fraction: a19 keys BOTH of its seeks on
        // it — an early frame reporting position≈0 (network open, before start-time settles)
        // is re-seeked to `snapshotPosition`, and a frame landing exactly at 0.05 then
        // satisfies `position <= 0.05` → the deep 30% re-seek. A raw 0.05 snapshot target
        // sits precisely on that boundary and re-arms the heuristic the start-time nudge
        // exists to dodge (observed on-device as webms hunting Matroska clusters backward
        // then timing out).
        var snapshotFraction = Double(position)
        if position < 0.3, let duration = Self.duration(of: media) {
            let fraction = position <= 0.05 ? Double(position) + 0.01 : Double(position)
            let startSeconds = duration.fractionalSeconds * fraction
            if startSeconds >= 1 {
                media.addOption(String(format: ":start-time=%.1f", startSeconds))
                snapshotFraction = fraction
            }
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
                thumbnailer.snapshotPosition = Float(snapshotFraction)

                // Retain BOTH for the whole fetch (delegate is weak on the thumbnailer).
                inFlight[id] = Fetch(thumbnailer: thumbnailer, delegate: delegate)

                // Hard timeout: races the delegate. Whichever resolves first wins;
                // `resolve` is resume-once (it removes the fetch), so the loser is a no-op.
                delegate.timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: remaining)
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
    /// The pre-parse resolved anything but `.done` (libvlc parse timeout/failure, our safety
    /// net, or task cancellation), or consumed the whole call budget by itself. Distinct from
    /// `.timedOut` so a caller's failure log attributes the loss to the demux/probe phase
    /// (e.g. an AVI index rebuild scanning the whole file) rather than the frame decode.
    case parseTimedOut
    /// VLC's delegate timed out, our hard timeout fired after a successful parse, or the
    /// enclosing task was cancelled mid-fetch. A media that opens but can't decode a frame
    /// also surfaces here — `VLCMediaThumbnailerDelegate` exposes no decode-error callback
    /// to distinguish it. Callers treat this and `.parseTimedOut` the same
    /// (poison-unless-cancelled); the split is diagnostic only.
    case timedOut
    case encodingFailed  // CGImage → PNG data failed
}

// MARK: - Pre-parse

/// Awaits one media's libvlc parse (its `parsedStatus` resolution) on the main actor.
/// One-shot: create a fresh instance per parse. Three resolvers race — the
/// `VLCMediaDelegate` callback (delivered on the main queue by the legacy events
/// configuration `configureVLCEvents()` installs), a safety sleeper for the failure
/// shapes where libvlc's documented triggers never fire, and task cancellation. The
/// first to resolve wins; the rest are no-ops (`finish` is resume-once).
///
/// The awaiter is kept alive for the whole parse by the `run(_:timeout:)` activation
/// itself; `media.delegate` is weak, and `safetyTask` captures `self` weakly, so
/// nothing cycles.
@MainActor
private final class MediaParseAwaiter: NSObject, VLCMediaDelegate {

    private var continuation: CheckedContinuation<VLCMediaParsedStatus, Never>?
    private var safetyTask: Task<Void, Never>?
    /// Retained for the parse so `parseStop()` on abort has a target.
    private var media: VLCMedia?

    /// Resolves once libvlc reports a terminal parse status, or with `.timeout` when
    /// `timeout` elapses or the enclosing task is cancelled (both abort the in-flight
    /// parse via `parseStop()`).
    func run(_ media: VLCMedia, timeout: Duration) async -> VLCMediaParsedStatus {
        // Already terminal (defensive — a fresh VLCMedia is `.init`): nothing to await.
        let status = media.parsedStatus
        if status == .done || status == .failed { return status }

        self.media = media
        media.delegate = self

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                // libvlc enforces the deadline itself (milliseconds; 0 means INFINITE,
                // hence the ≥1 clamp) and reports `.timeout` through the delegate.
                guard media.parse(options: [.parseLocal, .parseNetwork], timeout: Self.milliseconds(timeout)) == 0 else {
                    // Per the header doc, no callback ever comes after a -1 return.
                    finish(.failed)
                    return
                }
                // Safety net so a missing callback can't hang the fetch; libvlc's own
                // deadline should always beat this.
                safetyTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout + .seconds(2))
                    guard !Task.isCancelled else { return }
                    self?.abort()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.abort()
            }
        }
    }

    /// Stops an in-flight parse and resolves `.timeout`; a no-op if already resolved.
    private func abort() {
        media?.parseStop()
        finish(.timeout)
    }

    /// Resume-once: tears down the safety sleeper and the delegate hookup, then resumes.
    private func finish(_ status: VLCMediaParsedStatus) {
        guard let continuation else { return }
        self.continuation = nil
        safetyTask?.cancel()
        safetyTask = nil
        media?.delegate = nil
        media = nil
        continuation.resume(returning: status)
    }

    nonisolated func mediaDidFinishParsing(_ aMedia: VLCMedia) {
        // Delegate callbacks ride the legacy events config's main-queue delivery; assert it.
        let status = aMedia.parsedStatus
        MainActor.assumeIsolated {
            finish(status)
        }
    }

    /// `Duration` → whole milliseconds for `parse(options:timeout:)`, clamped to ≥ 1
    /// (0 would mean "no deadline") and to `Int32.max`.
    private static func milliseconds(_ duration: Duration) -> Int32 {
        let components = duration.components
        let ms = components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
        return Int32(clamping: max(1, ms))
    }
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
