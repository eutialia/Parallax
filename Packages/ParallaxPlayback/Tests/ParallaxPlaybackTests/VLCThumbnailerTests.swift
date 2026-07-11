import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import ParallaxPlayback

/// Decode PNG `Data` back into a `CGImage` to assert pixel dimensions / validity.
private func decodeImage(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          CGImageSourceGetCount(source) >= 1 else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

@Suite("VLCThumbnailer — failure paths (no live decode)")
@MainActor
struct VLCThumbnailerFailureTests {

    /// A non-routable smb:// URL must NOT hang: the hard timeout (or a libvlc
    /// timeout) resolves within the passed ceiling. Pins resume-once + hard-timeout.
    @Test("a non-routable URL throws .parseTimedOut within the ceiling, never hangs")
    func nonRoutableTimesOut() async {
        let url = URL(string: "smb://203.0.113.0/none/none.mkv")!
        let thumbnailer = VLCThumbnailer()
        do {
            _ = try await thumbnailer.thumbnailData(for: url, timeout: .seconds(3))
            Issue.record("expected a throw, got data")
        } catch let error as VLCThumbnailError {
            // The pre-parse never resolves .done for an unreachable host, so
            // .parseTimedOut is the expected outcome; .mediaRejected is acceptable if
            // libvlc rejects the URL at construction. Anything else is a regression.
            #expect(error == .parseTimedOut || error == .mediaRejected)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    /// Cancelling the enclosing task must resolve the continuation through the
    /// `onCancel` path — the one resolver the other tests don't exercise. A long
    /// `timeout` (30s) makes the point: if `onCancel` didn't resolve, the call would
    /// hang ~30s; a prompt throw proves cancellation resolved it, not the hard timeout.
    @Test("cancelling the task resolves promptly via onCancel, never hangs")
    func cancellationResolves() async {
        let url = URL(string: "smb://203.0.113.0/none/none.mkv")!
        let thumbnailer = VLCThumbnailer()
        let task = Task {
            try await thumbnailer.thumbnailData(for: url, timeout: .seconds(30))
        }
        task.cancel()
        let result = await task.result
        if case .success = result {
            Issue.record("expected a throw after cancellation, got data")
        }
    }

    /// An empty-path URL is the one libvlc reliably rejects at `VLCMedia(url:)`.
    @Test("an empty-path file URL throws .mediaRejected")
    func emptyPathRejected() async {
        let url = URL(fileURLWithPath: "")
        let thumbnailer = VLCThumbnailer()
        do {
            _ = try await thumbnailer.thumbnailData(for: url, timeout: .seconds(3))
            Issue.record("expected a throw, got data")
        } catch let error as VLCThumbnailError {
            // Empty path → media construction fails. Timeout cases tolerated: a build may
            // accept the URL and fail in either phase — libvlc has been observed resolving
            // the parse of a nonexistent path as .done under load, pushing the failure into
            // the fetch (.timedOut). The invariant under test is "throws within the ceiling,
            // never hangs, never returns data".
            #expect(error == .mediaRejected || error == .parseTimedOut || error == .timedOut)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}

@Suite("VLCThumbnailer — happy path (live VLC decode)")
@MainActor
struct VLCThumbnailerHappyPathTests {

    /// The bundled 160×90 (16:9) clip thumbnails to non-empty PNG data that decodes
    /// as a valid image whose aspect ratio matches the 16:9 source (NOT a stretched
    /// 320×240 / 4:3 box). This is the empirical aspect-behavior check called for in
    /// the task: with `width: 0, height: 320` libvlc should derive width from the
    /// source aspect.
    ///
    /// Runs live in the iOS Simulator test host — VLCKit's software decode of a tiny
    /// H.264 clip is feasible there (unlike a full `VLCMediaPlayer` render which needs
    /// a drawable). If a future VLCKit build can't decode in the sim, this is the test
    /// to mark device-only.
    @Test("bundled 16:9 clip yields valid PNG data with a 16:9-ish aspect")
    func bundledClipThumbnails() async throws {
        let url = try #require(
            Bundle.module.url(forResource: "tiny", withExtension: "mp4", subdirectory: "Fixtures"),
            "tiny.mp4 fixture missing from the test bundle"
        )
        let thumbnailer = VLCThumbnailer()
        let frame = try await thumbnailer.thumbnailData(for: url, height: 320, timeout: .seconds(20))
        #expect(!frame.data.isEmpty)

        let image = try #require(decodeImage(frame.data), "PNG data did not decode as an image")
        #expect(image.width > 0)
        #expect(image.height > 0)
        // Source is 16:9 (~1.778). With width derived from aspect, expect roughly that —
        // a forced 320×240 would be 1.333 (4:3). Wide tolerance absorbs rounding / any
        // SAR adjustment; the point is "not stretched to 4:3".
        let aspect = Double(image.width) / Double(image.height)
        #expect(aspect > 1.5, "expected a wide (16:9-ish) thumbnail, got aspect \(aspect) (\(image.width)x\(image.height))")
    }

    /// Positional snapshotting can't seek to a fraction without the duration, so a successful
    /// thumbnail should carry one. (If a future VLCKit build stops populating `media.length` in
    /// the sim, this is the assertion to relax — the app already tolerates a nil duration by
    /// falling back to file size.)
    @Test("a successful thumbnail carries the source duration")
    func bundledClipReportsDuration() async throws {
        let url = try #require(
            Bundle.module.url(forResource: "tiny", withExtension: "mp4", subdirectory: "Fixtures"),
            "tiny.mp4 fixture missing from the test bundle"
        )
        let thumbnailer = VLCThumbnailer()
        let frame = try await thumbnailer.thumbnailData(for: url, height: 320, timeout: .seconds(20))
        let duration = try #require(frame.duration, "expected libvlc to report the clip's length")
        #expect(duration > .zero)
    }
}
