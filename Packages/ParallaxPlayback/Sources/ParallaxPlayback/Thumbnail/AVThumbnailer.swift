import AVFoundation
import CoreGraphics
import Foundation
import ParallaxCore

/// Source-agnostic still-frame thumbnailer backed by AVFoundation's
/// `AVAssetImageGenerator`. Same result shape as `VLCThumbnailer`
/// (`VLCThumbnailFrame`) so callers can swap engines without caring who
/// produced the HEIC/JPEG bytes. Intended for containers already routed to
/// AVKit (probe-proven, hazard-free) over a localhost HTTP bridge — ranged
/// reads of the `moov` atom plus one nearest-keyframe decode, without spinning
/// up libvlc.
///
/// **Concurrency:** pinned to `@MainActor` to match `VLCThumbnailer`'s surface
/// (call sites hop once either way). Generation work itself is AVFoundation's
/// async API; the hard timeout bounds the WHOLE call — both phases — and
/// starves the abandoned work so a wedged loopback read cannot leak an
/// in-flight request.
@MainActor
public final class AVThumbnailer {

    /// Output bound, matching `VLCThumbnailer`'s frame tier (`width: 0, height: 320`): the width
    /// scales from the source aspect. Both engines feed the same tiles and the same disk cache, so
    /// they must produce the same-size still — a wider AV bound stored several times the pixels per
    /// entry and quietly invalidated `SMBThumbnailCache`'s "~30–120 KB per HEIC" budget.
    private static let targetHeight: CGFloat = 320

    public init() {}

    /// Generates a still frame from `url`, returned as HEIC data (JPEG on a host with no HEVC encoder).
    /// - Parameters:
    ///   - url: local file or http(s) URL to thumbnail (typically the loopback bridge).
    ///   - position: 0–1 fraction of the video duration to snapshot (default 0.3).
    ///   - timeout: hard ceiling on the WHOLE call — the `moov` fetch and the frame decode share
    ///     it. If neither phase finishes by then, throws `.timedOut`.
    /// - Returns: the encoded frame plus the source duration (nil if the asset duration is unresolved).
    /// - Throws: `CancellationError` if the enclosing task was cancelled (callers distinguish that
    ///   from a real failure), `AVThumbnailError` otherwise.
    public func thumbnailData(
        for url: URL,
        position: Float = 0.3,
        timeout: Duration = .seconds(20)
    ) async throws -> VLCThumbnailFrame {
        // Already cancelled on entry: bail before an `AVURLAsset` / generator pair exists at all.
        // `withTaskCancellationHandler` does fire its handler in that case, but the handler hops
        // through a `Task` while the body is still constructing — the one window where "cancel"
        // could arrive with no continuation installed to resolve. Checking here closes it.
        try Task.checkCancellation()

        let generation = AVThumbnailGeneration(url: url, maximumHeight: Self.targetHeight)

        // Race the WHOLE body against the deadline rather than arming it around the decode alone:
        // `load(.duration)` is the `moov` fetch, and against a stalled server it blocks for
        // AVFoundation's own 120s ceiling — the timeout this API promises has to cover it. A task
        // group can't express the race (`AVAssetImageGenerator` isn't Sendable, and a group awaits
        // its children anyway), so the racers resolve one MainActor-owned continuation; whoever is
        // first wins and the loser is a no-op.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<VLCThumbnailFrame, any Error>) in
                generation.install(continuation)
                generation.work = Task { @MainActor in
                    let result: Result<VLCThumbnailFrame, any Error>
                    do { result = .success(try await generation.run(position: position)) }
                    catch { result = .failure(error) }
                    generation.resolve(result)
                }
                generation.timer = Task { @MainActor in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    generation.abandon()
                    generation.resolve(.failure(AVThumbnailError.timedOut))
                }
            }
        } onCancel: {
            // Neither racer is a child task, so caller cancellation has to be forwarded by hand.
            // The hop is safe: the body runs on the MainActor and does not suspend before
            // `install(_:)`, so this Task cannot get a turn until the continuation is there to
            // resolve. (Cancellation that PREDATES the body is handled by the entry check above.)
            Task { @MainActor in
                generation.abandon()
                generation.resolve(.failure(CancellationError()))
            }
        }
    }
}

/// One in-flight generation: the AVFoundation pair plus the single continuation its three racers
/// (the body, the hard deadline, caller cancellation) compete to resolve. MainActor-only, so
/// "first one wins" needs no lock — the same shape as `VLCThumbnailer.resolve`.
@MainActor
private final class AVThumbnailGeneration {
    private let asset: AVURLAsset
    private let generator: AVAssetImageGenerator
    private var continuation: CheckedContinuation<VLCThumbnailFrame, any Error>?

    var work: Task<Void, Never>?
    var timer: Task<Void, Never>?

    init(url: URL, maximumHeight: CGFloat) {
        asset = AVURLAsset(url: url)
        generator = AVAssetImageGenerator(asset: asset)
        // Nearest keyframe either side — avoids a precise decode and is what makes
        // the grab fast over a ranged HTTP bridge (moov + one sample).
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        generator.appliesPreferredTrackTransform = true
        // 0 width lets AVFoundation scale the width from the source aspect (same idea
        // as VLCThumbnailer's `width: 0` default).
        generator.maximumSize = CGSize(width: 0, height: maximumHeight)
    }

    func install(_ continuation: CheckedContinuation<VLCThumbnailFrame, any Error>) {
        self.continuation = continuation
    }

    /// The two AVFoundation phases, in order. Both are ranged reads over the bridge, and both are
    /// inside the deadline the caller passed.
    func run(position: Float) async throws -> VLCThumbnailFrame {
        let loadedDuration = try await asset.load(.duration)
        let hasDuration = loadedDuration.isValid && !loadedDuration.isIndefinite && loadedDuration.seconds > 0
        let requestedTime = hasDuration
            ? CMTime(seconds: loadedDuration.seconds * Double(position), preferredTimescale: 600)
            : .zero

        let cgImage = try await image(at: requestedTime)

        let data: Data
        do {
            data = try ImageTranscode.encodeHEIC(cgImage)
        } catch {
            throw AVThumbnailError.encodingFailed
        }
        return VLCThumbnailFrame(
            data: data,
            duration: hasDuration ? .seconds(loadedDuration.seconds) : nil
        )
    }

    /// One keyframe decode, via the COMPLETION-HANDLER form rather than `image(at:)`. The async one
    /// wants the generator `sending`, which a reference held by an isolated object can never be —
    /// and the generator has to be held, or `abandon()` would have nothing to starve. The callback
    /// is `Sendable` and yields a plain `CGImage`, so nothing leaves this actor's region. Exactly
    /// one callback per request, cancellation included (`AVError.operationCancelled`).
    private func image(at time: CMTime) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { image, _, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? AVThumbnailError.timedOut)
                }
            }
        }
    }

    /// Starves both phases. Neither the `moov` load nor the decode observes Swift cancellation once
    /// it is stuck on a ranged read, so a racer that gives up has to say so to AVFoundation
    /// explicitly or the abandoned work keeps streaming from the share.
    func abandon() {
        asset.cancelLoading()
        generator.cancelAllCGImageGeneration()
    }

    /// First result wins; later ones are no-ops (the losing racer's frame is simply dropped).
    func resolve(_ result: Result<VLCThumbnailFrame, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        work?.cancel()
        timer?.cancel()
        work = nil
        timer = nil
        continuation.resume(with: result)
    }
}

public enum AVThumbnailError: Error, Sendable {
    /// The hard timeout fired before the `moov` load or the frame decode finished. Caller
    /// cancellation is NOT this — it surfaces as `CancellationError`.
    case timedOut
    /// CGImage → HEIC/JPEG data failed (genuine ImageIO failure, not a missing HEVC encoder).
    case encodingFailed
}
