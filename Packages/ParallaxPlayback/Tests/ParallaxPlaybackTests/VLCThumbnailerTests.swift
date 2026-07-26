import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import ParallaxPlayback

/// Decode the encoded thumbnail `Data` (HEIC, or JPEG on a host with no HEVC encoder)
/// back into a `CGImage` to assert pixel dimensions / validity. Codec-agnostic: ImageIO
/// sniffs the format.
private func decodeImage(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          CGImageSourceGetCount(source) >= 1 else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

/// The `Duration` → libvlc-milliseconds conversion feeding `VLCMedia.parse(timeout:)`.
/// Pure, and the clamps matter: 0 means INFINITE to libvlc (a hang), and an
/// out-of-range value would trap on the `Int32` conversion.
@Suite("MediaParseAwaiter — parse deadline conversion")
@MainActor
struct MediaParseDeadlineTests {

    @Test("whole milliseconds", arguments: [
        (Duration.milliseconds(1), Int32(1)),
        (.milliseconds(750), 750),
        (.seconds(3), 3_000),
        (.seconds(20), 20_000),
        (.milliseconds(2_500), 2_500),
    ] as [(Duration, Int32)])
    func convertsToMilliseconds(duration: Duration, expected: Int32) {
        #expect(MediaParseAwaiter.milliseconds(duration) == expected)
    }

    /// 0 would mean "no deadline" to libvlc, so a sub-millisecond or non-positive
    /// budget has to floor at 1 rather than disable the timeout entirely.
    @Test("a non-positive or sub-millisecond deadline floors at 1, never 0", arguments: [
        Duration.zero,
        .microseconds(1),
        .milliseconds(-5),
        .seconds(-30),
    ])
    func floorsAtOne(duration: Duration) {
        #expect(MediaParseAwaiter.milliseconds(duration) == 1)
    }

    @Test("an absurd deadline saturates instead of trapping")
    func saturates() {
        #expect(MediaParseAwaiter.milliseconds(.seconds(10_000_000_000)) == Int32.max)
    }
}

@Suite("VLCThumbnailer — failure paths (no live decode)")
@MainActor
struct VLCThumbnailerFailureTests {

    /// RFC 5737 TEST-NET-3 — guaranteed non-routable, so nothing here reaches a real host.
    private let unreachable = URL(string: "smb://203.0.113.0/none/none.mkv")!

    /// A non-routable smb:// URL must NOT hang: the pre-parse never resolves `.done` for
    /// an unreachable host, so the call fails inside the passed ceiling. Both accepted
    /// cases are pre-fetch failures — the point is that the loss is attributed to the
    /// demux/probe phase and never to a silent hang.
    @Test("a non-routable URL fails within the ceiling, never hangs")
    func nonRoutableTimesOut() async {
        let thumbnailer = VLCThumbnailer()
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await thumbnailer.thumbnailData(for: unreachable, timeout: .seconds(3))
            Issue.record("expected a throw, got data")
        } catch let error as VLCThumbnailError {
            // .parseTimedOut is the expected outcome; .mediaRejected is acceptable if
            // libvlc refuses the URL at construction. Anything else is a regression.
            #expect(error == .parseTimedOut || error == .mediaRejected)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        // The ceiling is the contract; a generous margin absorbs simulator scheduling.
        #expect(start.duration(to: clock.now) < .seconds(20))
    }

    /// Cancelling the enclosing task must resolve through the `onCancel` path — the one
    /// resolver the other tests don't exercise. The 30s `timeout` makes the point: if
    /// `onCancel` didn't resolve, this would sit for 30s; a prompt `VLCThumbnailError`
    /// proves cancellation resolved it, not the hard timeout.
    @Test("cancelling the task resolves promptly via onCancel, never hangs")
    func cancellationResolves() async {
        let thumbnailer = VLCThumbnailer()
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task {
            try await thumbnailer.thumbnailData(for: unreachable, timeout: .seconds(30))
        }
        task.cancel()
        switch await task.result {
        case .success:
            Issue.record("expected a throw after cancellation, got data")
        case .failure(let error):
            #expect(error is VLCThumbnailError, "unexpected error type: \(error)")
        }
        #expect(start.duration(to: clock.now) < .seconds(25),
                "resolved by the 30s hard timeout instead of onCancel")
    }

    /// An empty-path URL is the one libvlc reliably rejects at `VLCMedia(url:)`. The
    /// timeout cases stay tolerated: a build may accept the URL and fail in either phase
    /// — libvlc has been observed resolving the parse of a nonexistent path as `.done`
    /// under load, pushing the failure into the fetch. The invariant is "throws within
    /// the ceiling, never hangs, never returns data".
    @Test("an empty-path file URL throws rather than returning data")
    func emptyPathRejected() async {
        let thumbnailer = VLCThumbnailer()
        do {
            _ = try await thumbnailer.thumbnailData(for: URL(fileURLWithPath: ""), timeout: .seconds(3))
            Issue.record("expected a throw, got data")
        } catch let error as VLCThumbnailError {
            #expect(error == .mediaRejected || error == .parseTimedOut || error == .timedOut)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}

@Suite(
    "VLCThumbnailer — happy path (live VLC decode)",
    // Same philosophy as KeychainEntitlementProbe: skip where the environment, not the
    // code, can't deliver. Virtualized CI runners decode without hardware acceleration
    // and blow the 20s parse ceiling; CI reaches the sim test host via TEST_RUNNER_CI
    // in ci.yml (plain shell env never crosses into simulator processes).
    .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil,
             "live VLC software decode overruns its ceiling on virtualized CI runners")
)
@MainActor
struct VLCThumbnailerHappyPathTests {

    /// One live decode, every assertion on that single frame — the two previous tests
    /// each paid for their own 20s-ceiling decode of the same clip.
    ///
    /// Aspect: with `width: 0, height: 320` libvlc derives the width from the source
    /// aspect rather than stretching to a fixed box, so the 160×90 (16:9) source must
    /// come back wide (~1.778), NOT a 320×240 (1.333) 4:3 frame.
    ///
    /// Duration: positional snapshotting can't seek to a fraction without the length, so
    /// a successful frame should carry one. (If a future VLCKit build stops populating
    /// `media.length` in the sim, this is the assertion to relax — the app already
    /// tolerates a nil duration by falling back to file size.)
    @Test("the bundled 16:9 clip decodes to a wide image and carries its duration")
    func bundledClipThumbnails() async throws {
        let url = try #require(
            Bundle.module.url(forResource: "tiny", withExtension: "mp4", subdirectory: "Fixtures"),
            "tiny.mp4 fixture missing from the test bundle"
        )
        let frame = try await VLCThumbnailer().thumbnailData(for: url, height: 320, timeout: .seconds(20))

        #expect(frame.data.isEmpty == false)
        let image = try #require(decodeImage(frame.data), "thumbnail data did not decode as an image")
        #expect(image.width > 0)
        #expect(image.height > 0)
        let aspect = Double(image.width) / Double(image.height)
        #expect(aspect > 1.5,
                "expected a wide (16:9-ish) thumbnail, got aspect \(aspect) (\(image.width)x\(image.height))")

        let duration = try #require(frame.duration, "expected libvlc to report the clip's length")
        #expect(duration > .zero)
    }
}
