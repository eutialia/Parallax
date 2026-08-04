import Foundation
import Testing
import ParallaxCore
import ParallaxPlayback
@testable import Parallax

/// One routing row: a probe result plus the file size, and everything `route` must hand back for it.
struct RouteCase: Sendable, CustomTestStringConvertible {
    let name: String
    let probe: MediaProbeResult?
    let sizeBytes: Int64?
    let usesBridge: Bool
    let scheme: String
    let container: Container?
    let videoCodec: VideoCodec?
    let audioCodec: AudioCodec?
    var testDescription: String { name }
}

private let routeCases: [RouteCase] = [
    // The ONE bridge-eligible shape: a complete file whose container and both codecs are AVKit's.
    RouteCase(
        name: "complete h264/aac mp4 rides the bridge",
        probe: MediaProbeResult(container: .mp4, videoCodec: .known(.h264), audioCodec: .known(.aac), isComplete: true),
        sizeBytes: 1_234, usesBridge: true, scheme: "http",
        container: .mp4, videoCodec: .h264, audioCodec: .aac
    ),
    // Every remaining row is a single disqualifier applied to that same shape.
    RouteCase(
        name: "incomplete file — VLC owns the read-rate duration estimate",
        probe: MediaProbeResult(container: .mp4, videoCodec: .known(.h264), audioCodec: .known(.aac), isComplete: false),
        sizeBytes: 1_234, usesBridge: false, scheme: "smb",
        container: .mp4, videoCodec: .h264, audioCodec: .aac
    ),
    RouteCase(
        name: "dts audio — not an AVKit audio codec",
        probe: MediaProbeResult(container: .mp4, videoCodec: .known(.h264), audioCodec: .known(.dts), isComplete: true),
        sizeBytes: nil, usesBridge: false, scheme: "smb",
        container: .mp4, videoCodec: .h264, audioCodec: .dts
    ),
    RouteCase(
        name: "av1 video — not an AVKit video codec (selector rule 4)",
        probe: MediaProbeResult(container: .mp4, videoCodec: .known(.av1), audioCodec: .known(.aac), isComplete: true),
        sizeBytes: nil, usesBridge: false, scheme: "smb",
        container: .mp4, videoCodec: .av1, audioCodec: .aac
    ),
    // An unknown codec maps to nil in hints (only a known value survives) and never bridges.
    RouteCase(
        name: "a codec-unknown track, otherwise AVKit-clean",
        probe: MediaProbeResult(container: .mp4, videoCodec: .known(.h264), audioCodec: .unknown, isComplete: true),
        sizeBytes: nil, usesBridge: false, scheme: "smb",
        container: .mp4, videoCodec: .h264, audioCodec: nil
    ),
    // An UNRECOGNIZED container (ASF/OGM/FLV — magic bytes matched nothing): the probe
    // reports `container: nil, codecs: .none, isComplete: true`, the exact shape that used
    // to bridge-qualify (`.none` passes the `.unknown` gate, and the selector defaults to
    // AVKit with no container signal) and die in AVFoundation with "Cannot Open" — the
    // WMV decode-failed-error-page bug. An unidentified container must stay on VLC.
    RouteCase(
        name: "unrecognized container (wmv/asf) never bridges",
        probe: MediaProbeResult(container: nil, videoCodec: .none, audioCodec: .none, isComplete: true),
        sizeBytes: 9_876, usesBridge: false, scheme: "smb",
        container: nil, videoCodec: nil, audioCodec: nil
    ),
    // A failed/timed-out probe: no codec knowledge at all, but the size still rides along.
    RouteCase(
        name: "nil probe (timeout/failure)",
        probe: nil,
        sizeBytes: 42, usesBridge: false, scheme: "smb",
        container: nil, videoCodec: nil, audioCodec: nil
    ),
    // An otherwise AVKit-clean h264/aac mp4, but the probe proved AVPlayer would misplay it
    // (degenerate ctts + real B-frames): the hazard alone must disqualify the bridge, even
    // though every other bridge gate passes.
    RouteCase(
        name: "decode-order timestamp hazard — AVKit-clean file still stays on VLC",
        probe: MediaProbeResult(
            container: .mp4, videoCodec: .known(.h264), audioCodec: .known(.aac), isComplete: true,
            avPlayerHazards: [.decodeOrderTimestamps]
        ),
        sizeBytes: 1_234, usesBridge: false, scheme: "smb",
        container: .mp4, videoCodec: .h264, audioCodec: .aac
    ),
    // A DIFFERENT hazard case proves the route gate is set-agnostic — ANY non-empty
    // `avPlayerHazards` disqualifies the bridge, not just `.decodeOrderTimestamps`
    // specifically (that one gets its own timing-repair library options — see
    // `SMBPlaybackResolver.timingRepairLibraryOptions(for:)` below — but routing itself
    // doesn't special-case which hazard tripped).
    RouteCase(
        name: "interlaced-video hazard — AVKit-clean file still stays on VLC",
        probe: MediaProbeResult(
            container: .mp4, videoCodec: .known(.h264), audioCodec: .known(.aac), isComplete: true,
            avPlayerHazards: [.interlacedVideo]
        ),
        sizeBytes: 1_234, usesBridge: false, scheme: "smb",
        container: .mp4, videoCodec: .h264, audioCodec: .aac
    ),
]

/// The pure routing decision `SMBPlaybackResolver.route` makes from a probe result:
/// bridge (AVKit over the localhost HTTP bridge) vs the legacy `smb://`+VLC route,
/// plus the `PlaybackHints` each route carries. No I/O — every case is a table row.
@Suite("SMBPlaybackResolver.route")
struct SMBPlaybackRouteTests {
    @Test("bridge eligibility and hints, per probe shape", arguments: routeCases)
    func route(_ row: RouteCase) {
        let (hints, useBridge) = SMBPlaybackResolver.route(probe: row.probe, sizeBytes: row.sizeBytes)

        #expect(useBridge == row.usesBridge)
        #expect(hints.scheme == row.scheme)
        #expect(hints.container == row.container)
        #expect(hints.videoCodec == row.videoCodec)
        #expect(hints.audioCodec == row.audioCodec)
        // The size rides along on EVERY route, bridged or not — VLC needs it for its duration
        // estimate just as much as the bridge needs it for range requests.
        #expect(hints.fileSizeBytes == row.sizeBytes)
    }
}

/// `SMBPlaybackResolver.timingRepairLibraryOptions(for:)`: the pure decision behind the
/// libvlc instance flags that repair the `.decodeOrderTimestamps` hazard (a broken vout
/// clock drops ~half the frames — see the method's own doc for the full mechanism).
@Suite("SMBPlaybackResolver.timingRepairLibraryOptions")
struct SMBTimingRepairLibraryOptionsTests {
    @Test("nil probe → nil (no evidence of the hazard)")
    func nilProbe() {
        #expect(SMBPlaybackResolver.timingRepairLibraryOptions(for: nil) == nil)
    }

    @Test("a decode-order-timestamps probe → the two repair flags")
    func decodeOrderHazard() {
        let probe = MediaProbeResult(
            container: .mp4, videoCodec: .known(.h264), audioCodec: .known(.aac), isComplete: true,
            avPlayerHazards: [.decodeOrderTimestamps]
        )
        #expect(SMBPlaybackResolver.timingRepairLibraryOptions(for: probe) == [
            "--no-drop-late-frames", "--no-skip-frames",
        ])
    }

    @Test("a different hazard → nil (scoped to this one defect, not hazards in general)")
    func otherHazard() {
        let probe = MediaProbeResult(
            container: .mp4, videoCodec: .known(.h264), audioCodec: .known(.aac), isComplete: true,
            avPlayerHazards: [.interlacedVideo]
        )
        #expect(SMBPlaybackResolver.timingRepairLibraryOptions(for: probe) == nil)
    }
}

/// The container-probe deadline race: a wedged SMB read must be abandoned at the
/// deadline so the loading veil is never held hostage to AMSMB2's 15s socket timeout.
@Suite("SMBPlaybackResolver.probeWithDeadline")
struct SMBProbeDeadlineTests {

    /// A reader whose `read` never returns — models an SMB share stuck in a native
    /// socket read that cancellation can't unwedge (exactly the AMSMB2 failure mode).
    private struct HangingReader: RandomAccessReading {
        var fileSize: UInt64 { get async throws { 1_000_000 } }
        func read(offset: UInt64, length: Int) async throws -> Data {
            // Never resumes; not resumed on cancellation either — the point of the test.
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return Data()
        }
    }

    @Test("a wedged reader is abandoned at the deadline, returning nil")
    func wedgedReaderTimesOut() async {
        let clock = ContinuousClock()
        let start = clock.now
        // 0.2s deadline (not the 4s default) so the test proves the race without a
        // wall-clock stall; the generous 6s bound only guards against CI scheduling flake.
        let result = await SMBPlaybackResolver.probeWithDeadline(HangingReader(), seconds: 0.2)
        let elapsed = start.duration(to: clock.now)

        #expect(result == nil)
        #expect(elapsed < .seconds(6))
    }

    @Test("a fast in-memory probe returns its result well before the deadline")
    func fastProbeReturnsResult() async {
        // A minimal ftyp/qt header is enough for the probe to classify the container;
        // it returns immediately, so the deadline task never fires.
        var bytes = Data([0, 0, 0, 12])
        bytes.append(contentsOf: Array("ftypqt  ".utf8))
        let reader = InMemoryRandomAccessReader(data: bytes)

        let result = await SMBPlaybackResolver.probeWithDeadline(reader, seconds: 5)

        #expect(result != nil)
        #expect(result?.container == .mov)
    }
}
