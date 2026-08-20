import Testing
import Foundation
import CoreMedia
#if canImport(MobileVLCKit)
import MobileVLCKit
#else
import TVVLCKit
#endif
import ParallaxCore
import ParallaxPlaybackTestSupport
@testable import ParallaxPlayback

@Suite("VLCKitEngine — live-player configuration")
@MainActor
struct VLCKitEngineTests {

    /// PiP is OFF on this engine: MobileVLCKit 3.x ships no Picture-in-Picture API at all
    /// (the `VLCPictureInPicture*` protocols are 4.x-only), and this flag is what hides the
    /// button. AVKit still reports `supportsPiP: true`, so the two engines must differ here.
    @Test("capabilities: Now Playing yes, PiP and video AirPlay no")
    func capabilities() {
        #expect(VLCKitEngine().capabilities == PlaybackEngineCapabilities(
            supportsPiP: false, supportsVideoAirPlay: false, supportsNowPlayingIntegration: true
        ))
    }

    /// A non-finite target must be dropped before it can be turned into a millisecond
    /// offset — and observably so: the player's clock must be left exactly where it was,
    /// not written with a garbage `VLCTime`.
    @Test("seek with a non-finite CMTime leaves the player's clock untouched",
          arguments: [CMTime.invalid, .indefinite, .positiveInfinity, .negativeInfinity])
    func seekNonFiniteIsANoOp(time: CMTime) async {
        let engine = VLCKitEngine()
        let before = engine.vlcPlayer.time.intValue
        await engine.seek(to: time)
        #expect(engine.vlcPlayer.time.intValue == before)
        #expect(engine.vlcPlayer.isPlaying == false)
    }

    /// The exit latch is what makes `endAudio()` TERMINAL. A scrub commit coalesced just
    /// before the close button lands inside the dismiss animation and calls `play()`, which
    /// unmutes and re-issues play, so audio comes back for the rest of the slide-out.
    @Test("endAudio latches the session closed: a late play() can't revive it")
    func endAudioLatchesPlayShut() async {
        let engine = VLCKitEngine()
        #expect(engine.audioEnded == false)

        await engine.endAudio()
        // `endAudio()` returns while its stop is still detached; join it before reading the
        // player, or the assertions race the very thread the latch exists to outrun.
        await engine.awaitPendingStop()
        #expect(engine.audioEnded)
        #expect(engine.vlcPlayer.audio?.isMuted == true)

        await engine.play()
        #expect(engine.audioEnded)   // play must not lift the latch
        // The real witness: `play()`'s first act on an honored call is lifting the mute, so a
        // mute still standing here is proof the guard returned before touching the input.
        // (`isPlaying` is NOT a witness on a media-less player: it reads false either way.)
        #expect(engine.vlcPlayer.audio?.isMuted == true)
        await engine.teardown()
    }

    /// The other half of the latch, and the reason it is a TRANSPORT gate rather than a play
    /// gate: the HUD calls `engine?.pause()` directly (the iOS drag begin, the tvOS reducer's
    /// `.pause` effect) and the outgoing player stays hit-testable for the whole slide-out, so
    /// a scrubber grabbed mid-dismiss would drive the same non-Sendable player `endAudio()`'s
    /// detached `stop()` is still winding down. The observable is the beat: an honored
    /// `pause()` republishes the seek hold (see `VLCKitPauseBeatTests`), so the arrangement
    /// below emits TWO paused beats without the latch and only `seek()`'s own with it.
    @Test("endAudio latches the session closed: a late pause() can't drive the player either")
    func endAudioLatchesPauseShut() async throws {
        let engine = VLCKitEngine()
        try await engine.load(.fixture(url: URL(fileURLWithPath: "/dev/null")))
        await engine.seek(to: CMTime(seconds: 42, preferredTimescale: 1_000))
        await engine.endAudio()
        await engine.awaitPendingStop()

        await engine.pause()

        await engine.teardown()
        var positions: [Double] = []
        for await state in engine.state {
            if case .paused(let position, _, _) = state { positions.append(CMTimeGetSeconds(position)) }
        }
        #expect(positions == [42.0])
    }

    /// Only a fresh `load()` re-opens the session. It has to: the transcode reload reuses
    /// this engine, and a latch that outlived the reload would leave the new stream silent
    /// and stopped.
    @Test("a fresh load clears the exit latch")
    func loadClearsTheExitLatch() async throws {
        let engine = VLCKitEngine()
        await engine.endAudio()
        #expect(engine.audioEnded)
        #expect(engine.vlcPlayer.audio?.isMuted == true)

        try await engine.load(.fixture(url: URL(fileURLWithPath: "/dev/null")))
        #expect(engine.audioEnded == false)
        // Clearing the flag is only half the claim: prove the session actually reopens by
        // letting a `play()` through and watching it lift the exit mute it would have been
        // refused a moment ago.
        await engine.play()
        #expect(engine.vlcPlayer.audio?.isMuted == false)
        await engine.teardown()
    }

    /// Exit is not one call: the close button ends audio and the presenter's dismissal ends
    /// it again. The second pass must be inert, and above all must not race a SECOND detached
    /// stop against the first, on the same non-Sendable player.
    @Test("endAudio is idempotent: the second pass spawns no second stop")
    func endAudioIsIdempotent() async {
        let engine = VLCKitEngine()
        await engine.endAudio()
        await engine.awaitPendingStop()   // first stop settled AND its reference dropped
        await engine.endAudio()
        #expect(engine.pendingStopTask == nil)
        #expect(engine.audioEnded)
        #expect(engine.vlcPlayer.isPlaying == false)
        await engine.teardown()
    }

    /// `teardown()` drives the same non-Sendable `VLCMediaPlayer` the exit stop is still
    /// winding down (drawable → delegate → stop). It joins first, or the two run concurrently
    /// on two threads, the shape libvlc's own teardown aborts on.
    @Test("teardown joins endAudio's detached stop before it touches the player")
    func teardownJoinsPendingStop() async {
        let engine = VLCKitEngine()
        await engine.endAudio()
        await engine.teardown()
        #expect(engine.pendingStopTask == nil)
    }

    /// `silence()` is the RESUMABLE mute (the transcode reload's freeze → silence → reload →
    /// play round-trip depends on `play()` unmuting). If it set the terminal latch, every
    /// track switch would come back silent and stopped.
    @Test("silence does NOT latch: the reload round-trip must stay resumable")
    func silenceDoesNotLatch() async {
        let engine = VLCKitEngine()
        await engine.silence()
        #expect(engine.audioEnded == false)
        await engine.teardown()
    }
}

/// Everything below is a pure static seam — the engine's decision logic, testable
/// without a live decode. The `applyOptions`/transport paths need a real input and stay
/// device-verified.
@Suite("VLCKitEngine — pure time conversion")
@MainActor
struct VLCKitTimeConversionTests {

    /// POSITION: 0 legitimately means 0:00, and libvlc's pre-first-frame sentinel (-1)
    /// clamps to it rather than producing a negative time.
    @Test("vlcTimeToCMTime clamps non-positive ms to zero and converts positives",
          arguments: [(Int32(-1), 0.0), (0, 0.0), (1, 0.001), (2_000, 2.0), (3_723_500, 3723.5)])
    func vlcTimeToCMTime(ms: Int32, seconds: Double) {
        #expect(CMTimeGetSeconds(VLCKitEngine.vlcTimeToCMTime(ms: ms)) == seconds)
    }

    /// DURATION: a non-positive length means "not resolvable from the bytes we have"
    /// (truncated file, trailing moov/Cues in the missing tail) — that is *indeterminate*,
    /// not 0:00, so it maps to AVFoundation's own `.indefinite` sentinel and the app
    /// derives one `hasKnownDuration` truth from `CMTime.isNumeric`.
    @Test("vlcDurationToCMTime maps an unresolved length to .indefinite",
          arguments: [Int32(-1), 0])
    func unknownDuration(ms: Int32) {
        #expect(VLCKitEngine.vlcDurationToCMTime(ms: ms) == .indefinite)
    }

    @Test("vlcDurationToCMTime converts a resolved length to seconds",
          arguments: [(Int32(1), 0.001), (4_000, 4.0), (7_200_000, 7200.0)])
    func knownDuration(ms: Int32, seconds: Double) {
        let duration = VLCKitEngine.vlcDurationToCMTime(ms: ms)
        #expect(duration.isNumeric)
        #expect(CMTimeGetSeconds(duration) == seconds)
    }

    /// `seek()` once clamped its lower bound to `Int32.min`, admitting a negative target
    /// for a rewind-before-zero scrub — but `liveBeat` suppresses `positionMs < 0`, so
    /// the optimistic beat vanished AND the poll's pending target sat somewhere
    /// `player.time` (>= 0) could never reach, freezing live tracking until the fallback.
    @Test("clampSeekMs floors negatives at 0 and saturates at Int32.max", arguments: [
        (-5.0, Int32(0)),
        (0.0, 0),
        (8.0, 8_000),
        (0.001, 1),
        (Double(Int32.max), Int32.max),
    ] as [(Double, Int32)])
    func clampSeekMs(seconds: Double, expected: Int32) {
        #expect(VLCKitEngine.clampSeekMs(seconds: seconds) == expected)
    }

    /// `startMs` is `clampSeekMs` plus a reject-if-nothing-to-resume-to policy: only a
    /// finite, strictly positive resume point produces an offset.
    @Test("startMs rejects anything that isn't a real resume point", arguments: [
        CMTime?.none,
        CMTime.invalid,
        CMTime.indefinite,
        CMTime.zero,
        CMTime(seconds: -30, preferredTimescale: 1000),
    ])
    func startMsRejectsNonResumePoints(time: CMTime?) {
        #expect(VLCKitEngine.startMs(from: time) == nil)
    }

    @Test("startMs converts a positive resume point to milliseconds",
          arguments: [(1.0, Int32(1_000)), (90.5, 90_500)])
    func startMsConverts(seconds: Double, expected: Int32) {
        let time = CMTime(seconds: seconds, preferredTimescale: 1000)
        #expect(VLCKitEngine.startMs(from: time) == expected)
    }
}

@Suite("VLCKitEngine — beat emission")
struct VLCKitBeatTests {

    @Test("positionState maps isPlaying onto .playing/.paused with converted times",
          arguments: [true, false])
    func positionStateMapsTransport(isPlaying: Bool) {
        let state = VLCKitEngine.positionState(isPlaying: isPlaying, positionMs: 1_000, durationMs: 4_000)
        switch (isPlaying, state) {
        case (true, .playing(let p, let d, let buffered)),
             (false, .paused(let p, let d, let buffered)):
            #expect(CMTimeGetSeconds(p) == 1.0)
            #expect(CMTimeGetSeconds(d) == 4.0)
            // libvlc exposes no loaded-range query, so the bar's instant-seek layer is
            // deliberately unfed on this engine.
            #expect(buffered == nil)
        default:
            Issue.record("isPlaying=\(isPlaying) produced \(state)")
        }
    }

    /// Frames are rendering (real position) but the length never resolved: the beat must
    /// still ship, with an indeterminate duration, so the player leaves `.loading`. The
    /// old guard required `durationMs > 0` and wedged incomplete media forever.
    @Test("an unknown length still produces a beat carrying the real position")
    func beatSurvivesUnknownLength() throws {
        let direct = VLCKitEngine.positionState(isPlaying: true, positionMs: 5_000, durationMs: 0)
        let gated = try #require(VLCKitEngine.liveBeat(isPlaying: true, positionMs: 5_000, durationMs: 0))
        for state in [direct, gated] {
            guard case .playing(let position, let duration, _) = state else {
                Issue.record("expected .playing, got \(state)"); continue
            }
            #expect(CMTimeGetSeconds(position) == 5.0)
            #expect(duration == .indefinite)
        }
    }

    /// `player.time` reads the VLC_TICK_INVALID sentinel (-1) before the first frame.
    /// Emitting it would snap `lastPosition` to 0:00 and risk losing the resume point —
    /// the guard is on POSITION, not duration.
    @Test("liveBeat suppresses the pre-first-frame sentinel position")
    func liveBeatSuppressesSentinelPosition() {
        #expect(VLCKitEngine.liveBeat(isPlaying: true, positionMs: -1, durationMs: 4_000) == nil)
        #expect(VLCKitEngine.liveBeat(isPlaying: false, positionMs: -1, durationMs: 0) == nil)
        #expect(VLCKitEngine.liveBeat(isPlaying: true, positionMs: 0, durationMs: 4_000) != nil)
    }
}

@Suite("VLCKitEngine — poll gates")
@MainActor
struct VLCKitPollGateTests {

    /// Seek target 480_000ms (08:00). ±3s absorbs a keyframe-snapped landing; a far
    /// transient reading is suppressed until either convergence or the poll budget.
    @Test("seekHasSettled", arguments: [
        ("far forward transient", Int32(600_000), Int32(480_000), 1, false),
        ("far backward transient", 180_000, 300_000, 1, false),
        ("exact landing", 480_000, 480_000, 2, true),
        ("-2.5s keyframe snap", 477_500, 480_000, 2, true),
        ("+2.9s keyframe snap", 482_900, 480_000, 2, true),
        ("just outside tolerance", 483_100, 480_000, 2, false),
        ("one poll short of the budget", 600_000, 480_000, 9, false),
        ("budget spent — resume anyway", 600_000, 480_000, 10, true),
    ] as [(String, Int32, Int32, Int, Bool)])
    func seekHasSettled(label: String, now: Int32, target: Int32, polls: Int, expected: Bool) {
        #expect(VLCKitEngine.seekHasSettled(now: now, target: target, polls: polls) == expected, "\(label)")
    }

    /// While VLC's clock sits at the flush anchor the re-decode hasn't produced output at
    /// the new rate yet, so keep publishing the buffering hold rather than resume onto a
    /// frozen counter — but never hold forever.
    @Test("flushBridgeShouldResume", arguments: [
        ("pinned at the anchor", Int32(60_000), Int32(60_000), 1, false),
        ("within the +200ms jitter window", 60_150, 60_000, 2, false),
        ("exactly at the jitter edge", 60_200, 60_000, 2, false),
        ("advanced past the anchor", 61_000, 60_000, 2, true),
        ("one tick short of the budget", 60_000, 60_000, 7, false),
        ("budget spent — resume anyway", 60_000, 60_000, 8, true),
    ] as [(String, Int32, Int32, Int, Bool)])
    func flushBridgeShouldResume(label: String, now: Int32, anchor: Int32, ticks: Int, expected: Bool) {
        #expect(VLCKitEngine.flushBridgeShouldResume(now: now, anchor: anchor, ticks: ticks) == expected, "\(label)")
    }

    /// libvlc applies `rate` to the active input, so a rate chosen before the input
    /// existed never took and must be re-asserted once playing. The epsilon stops a
    /// redundant write on every 500ms tick.
    @Test("shouldReassertRate", arguments: [
        (Float(1.0), Float(1.5), true),
        (1.5, 1.0, true),
        (1.0, 1.0, false),
        (2.0, 2.0, false),
        (1.4999, 1.5, false),      // inside the float tolerance
        (1.49, 1.5, true),         // outside it
    ] as [(Float, Float, Bool)])
    func shouldReassertRate(current: Float, desired: Float, expected: Bool) {
        #expect(VLCKitEngine.shouldReassertRate(current: current, desired: desired) == expected)
    }

    /// The scrub-commit wedge: the user wants playback, the input reports paused, and the
    /// input is alive. `.opening` is excluded (the initial `play()` is still landing) and
    /// the terminals are excluded so a finished/failed input can't be restarted into a
    /// ghost session. `.esAdded` — 3.x's "an elementary stream announced itself", which the
    /// player caches as a state — lands during the open, so it sits with `.opening`.
    @Test("shouldReassertPlay fires only inside the live-but-not-playing wedge", arguments: [
        (true, false, VLCMediaPlayerState.paused, true),
        (true, false, .buffering, true),
        (true, false, .playing, true),      // isPlaying lagging a raced state read
        (true, true, .playing, false),      // already playing
        (false, false, .paused, false),     // paused by intent
        (true, false, .stopped, false),
        (true, false, .ended, false),
        (true, false, .error, false),
        (true, false, .opening, false),
        (true, false, .esAdded, false),
    ] as [(Bool, Bool, VLCMediaPlayerState, Bool)])
    func shouldReassertPlay(desiredPlaying: Bool, isPlaying: Bool, state: VLCMediaPlayerState, expected: Bool) {
        #expect(VLCKitEngine.shouldReassertPlay(
            desiredPlaying: desiredPlaying, isPlaying: isPlaying, state: state
        ) == expected)
    }

    /// The exit latch, as the gate `play()` and `pause()` both read. Terminal in one
    /// direction only: once `endAudio()` has stopped the input for the dismissal, nothing but
    /// a fresh `load()` may let a transport command through.
    @Test("shouldHonorTransport is false exactly while the exit latch stands", arguments: [
        (false, true),
        (true, false),
    ] as [(Bool, Bool)])
    func shouldHonorTransport(audioEnded: Bool, expected: Bool) {
        #expect(VLCKitEngine.shouldHonorTransport(audioEnded: audioEnded) == expected)
    }
}

/// libvlc's `position` is `time / length`, useless when the length never resolves. The
/// length-INDEPENDENT signal is `statistics.demuxReadBytes` — NOT the input `readBytes`,
/// which races ahead with the network read-ahead cache (a device trace showed 16.9 MB
/// read vs 154 KB demuxed in 3s, yielding a nonsense 56s total).
@Suite("VLCKitEngine — duration estimate for incomplete media")
struct VLCKitDurationEstimateTests {

    /// Real device trace: 297 MB file, 3.05s played, 154 KB demuxed → ~100 minutes.
    @Test("derives the total from fileSize × playedMs ÷ demuxReadBytes")
    func happyMath() {
        #expect(VLCKitEngine.estimateDurationMs(
            fileSizeBytes: 311_758_144, playedMs: 3_050, demuxReadBytes: 157_849
        ) == 6_023_873)
    }

    /// Below the floor the bounded read-ahead cache hasn't amortized, so the observed
    /// rate is a cache-fill spike rather than the content byte-rate.
    @Test("returns nil until the estimate floor has elapsed")
    func earlyWindowHasNoEstimate() {
        let floor = VLCKitEngine.estimateFloorMs
        #expect(VLCKitEngine.estimateDurationMs(
            fileSizeBytes: 311_758_144, playedMs: floor - 1, demuxReadBytes: 50_000
        ) == nil)
        #expect(VLCKitEngine.estimateDurationMs(
            fileSizeBytes: 311_758_144, playedMs: floor, demuxReadBytes: 50_000
        ) != nil)
    }

    /// A bad signal must fall back to the indeterminate bar, never to a nonsense total
    /// (and never divide by zero).
    @Test("degenerate inputs produce no estimate", arguments: [
        ("no file size", Int64(0), Int32(60_000), 157_849),
        ("negative file size", -1, 60_000, 157_849),
        ("nothing demuxed", 311_758_144, 60_000, 0),
        ("demuxed more than the whole file — estimate would undercut what already played",
         1_000_000, 60_000, 2_000_000),
    ] as [(String, Int64, Int32, Int)])
    func degenerateInputs(label: String, fileSize: Int64, playedMs: Int32, demuxed: Int) {
        #expect(VLCKitEngine.estimateDurationMs(
            fileSizeBytes: fileSize, playedMs: playedMs, demuxReadBytes: demuxed
        ) == nil, "\(label)")
    }

    /// An overflowing estimate is discarded rather than truncated into a bogus runtime.
    @Test("an estimate beyond Int32.max is discarded")
    func overflowIsDiscarded() {
        #expect(VLCKitEngine.estimateDurationMs(
            fileSizeBytes: .max, playedMs: 60_000, demuxReadBytes: 1
        ) == nil)
    }
}

/// 3.x has no `Track` object: the player vends parallel `*TrackIndexes` / `*TrackNames`
/// arrays, prepends a "Disabled" pseudo-track at id -1, and carries no language at all.
/// These are the seams that turn that into the engine's `TrackInventory`.
@Suite("VLCKitEngine — 3.x track array decoding")
struct VLCKitTrackArrayTests {

    /// The "Disabled" entry is a UI affordance for VLC's own menus, not a stream — leaking
    /// it would put a phantom "Disable" row in the app's track menu and let `setAudioTrack`
    /// write -1 (= turn audio off) as if it were a real selection.
    @Test("trackDescriptors drops the Disabled pseudo-track and pairs id with name")
    func dropsDisabledPseudoTrack() {
        let descriptors = VLCKitEngine.trackDescriptors(
            indexes: [NSNumber(value: -1), NSNumber(value: 3), NSNumber(value: 7)],
            names: ["Disable", "English", "Commentary"]
        )
        #expect(descriptors == [
            .init(id: 3, name: "English"),
            .init(id: 7, name: "Commentary"),
        ])
    }

    /// The arrays come back untyped (`[Any]`), so a slot that isn't the documented
    /// NSNumber/NSString pair is skipped rather than crashing the whole inventory.
    @Test("trackDescriptors skips malformed slots instead of trapping")
    func skipsMalformedSlots() {
        let descriptors = VLCKitEngine.trackDescriptors(
            indexes: [NSNumber(value: 1), "not a number", NSNumber(value: 5)],
            names: ["English", "French", NSNull()]
        )
        #expect(descriptors == [.init(id: 1, name: "English")])
    }

    /// Ragged arrays (a name array that hasn't caught up with a just-discovered index)
    /// must truncate to the shorter one, never index out of bounds.
    @Test("trackDescriptors truncates to the shorter array")
    func truncatesRaggedArrays() {
        let descriptors = VLCKitEngine.trackDescriptors(
            indexes: [NSNumber(value: 1), NSNumber(value: 2)],
            names: ["English"]
        )
        #expect(descriptors == [.init(id: 1, name: "English")])
    }

    /// The player-side arrays carry no language, so it is joined in from the parsed
    /// container by libvlc track id — that shared id is what makes the join valid.
    @Test("trackLanguages joins language onto the libvlc track id")
    func parsesTrackLanguages() {
        let languages = VLCKitEngine.trackLanguages(from: [
            [VLCMediaTracksInformationId: NSNumber(value: 3),
             VLCMediaTracksInformationLanguage: "eng"],
            [VLCMediaTracksInformationId: NSNumber(value: 7),
             VLCMediaTracksInformationLanguage: "fre"],
        ])
        #expect(languages == [3: "eng", 7: "fre"])
    }

    /// An untagged stream, a missing id, and an empty language tag all mean "no language"
    /// — never an empty-string language the app's preference matching would try to match.
    @Test("trackLanguages skips entries with no usable language")
    func skipsUntaggedTracks() {
        let languages = VLCKitEngine.trackLanguages(from: [
            [VLCMediaTracksInformationId: NSNumber(value: 1)],                  // no language key
            [VLCMediaTracksInformationId: NSNumber(value: 2),
             VLCMediaTracksInformationLanguage: ""],                            // empty tag
            [VLCMediaTracksInformationLanguage: "eng"],                         // no id
            "not a dictionary",
        ])
        #expect(languages.isEmpty)
    }

    /// libvlc packs a fourcc least-significant-byte first, so the raw NSNumber the codec key
    /// carries reads BACKWARDS from the obvious big-endian reading. Getting this wrong would
    /// silently match nothing (or the wrong codec), so the byte order is pinned here with the
    /// two values documented by VideoLAN: 0x34363268 is "h264", 0x64687274 is "trhd".
    @Test("fourccString decodes libvlc's little-endian packing", arguments: [
        (UInt32(0x3436_3268), "h264"),
        (UInt32(0x6468_7274), "trhd"),
        (UInt32(0x2070_6C6D), "mlp "),
        (UInt32(0), ""),                    // not printable → matches nothing
        (UInt32(0xFFFF_FFFF), ""),
    ] as [(UInt32, String)])
    func decodesFourcc(value: UInt32, expected: String) {
        #expect(VLCKitEngine.fourccString(from: value) == expected)
    }

    /// The undecodable set is what keeps the menu honest, so both spellings of Dolby's
    /// lossless codec have to be caught — and nothing else may be.
    @Test("undecodableTrackIDs flags the TrueHD/MLP tracks and only those")
    func flagsUndecodableTracks() {
        let ids = VLCKitEngine.undecodableTrackIDs(from: [
            [VLCMediaTracksInformationId: NSNumber(value: 1),
             VLCMediaTracksInformationCodec: NSNumber(value: UInt32(0x6468_7274))],   // trhd
            [VLCMediaTracksInformationId: NSNumber(value: 2),
             VLCMediaTracksInformationCodec: NSNumber(value: UInt32(0x2070_6C6D))],   // mlp
            [VLCMediaTracksInformationId: NSNumber(value: 3),
             VLCMediaTracksInformationCodec: NSNumber(value: UInt32(0x2032_3561))],   // "a52 " (AC3)
        ])
        #expect(ids == [1, 2])
    }

    /// Unparsed media, a missing codec key, and a malformed entry all mean "we don't know
    /// the codec" — which must never disable a track the engine could actually play.
    @Test("undecodableTrackIDs flags nothing when the codec is unknown")
    func unknownCodecFlagsNothing() {
        let ids = VLCKitEngine.undecodableTrackIDs(from: [
            [VLCMediaTracksInformationId: NSNumber(value: 1)],                        // no codec key
            [VLCMediaTracksInformationCodec: NSNumber(value: UInt32(0x6468_7274))],   // no id
            [VLCMediaTracksInformationId: NSNumber(value: 2),
             VLCMediaTracksInformationCodec: "trhd"],                                 // not a number
            "not a dictionary",
        ])
        #expect(ids.isEmpty)
    }

    /// Selection round-trips through the public `TrackID`: the inventory stringifies the
    /// libvlc id and `setAudioTrack` parses it back. Ids from the other two namespaces must
    /// not resolve, or an AVKit option index could be written onto VLC's track selector.
    @Test("trackIndex round-trips the VLC namespace and rejects the others", arguments: [
        (TrackID.vlc("3"), Int32(3)),
        (.vlc("-1"), -1),
        (.vlc("notanumber"), nil),
        (.avKitOption(2), nil),
        (.jellyfinStream(2), nil),
    ] as [(TrackID, Int32?)])
    func trackIndexRoundTrip(id: TrackID, expected: Int32?) {
        #expect(VLCKitEngine.trackIndex(from: id) == expected)
    }
}

/// The 3.x clock trap: `VLCTime.nullTime.intValue` is **0**, not -1. Reading `intValue`
/// alone would turn "libvlc has no clock yet" into a real 0:00 beat — snapping the
/// scrubber and risking a 0:00 progress report that loses the resume point. Only the
/// nullable `value` separates the two, which is what `validClockMs` reads.
@Suite("VLCKitEngine — VLCTime null handling")
struct VLCKitTimeNullTests {

    @Test("nullTime reads 0 through intValue — the reason validClockMs exists")
    func nullTimeIntValueIsZero() {
        #expect(VLCTime.null().intValue == 0)
        #expect(VLCTime.null().value == nil)
    }

    /// The distinction is only useful if the player's live clock reports a genuine 0:00 as
    /// a real value. It does: `VLCMediaPlayer` seeds `_cachedTime` with `nullTime` and
    /// refreshes it through `timeWithNumber:`, which keeps a zero as `NSNumber(0)`.
    /// `VLCTime(int:)` is the odd one out — it drops a zero and yields a null time — so a
    /// 0:00 built that way is indistinguishable from "no clock" and must never be used as
    /// a stand-in for a live position sample.
    @Test("timeWithNumber keeps a zero; the int initializer discards it")
    func zeroSurvivesOnlyThroughTheNumberInitializer() {
        #expect(VLCTime(number: NSNumber(value: 0)).value == 0)
        #expect(VLCTime(int: 0).value == nil)
    }

    /// Not parameterized: `VLCTime` isn't `Sendable`, so it can't cross into a Swift
    /// Testing `arguments:` list — the instances have to be built inside the test body.
    @Test("validClockMs is nil only when libvlc has no value")
    func validClockMs() {
        #expect(VLCKitEngine.validClockMs(.null()) == nil)
        #expect(VLCKitEngine.validClockMs(VLCTime(number: NSNumber(value: 0))) == 0)
        #expect(VLCKitEngine.validClockMs(VLCTime(int: 1_500)) == 1_500)
    }

    /// An out-of-range millisecond value saturates rather than trapping the whole poll.
    @Test("validClockMs clamps an out-of-range value instead of trapping")
    func clampsOutOfRange() {
        let huge = VLCTime(number: NSNumber(value: Int64(Int32.max) + 5_000))
        #expect(VLCKitEngine.validClockMs(huge) == Int32.max)
    }
}

@Suite("VLCKitEngine — track mapping")
@MainActor
struct VLCKitEngineTrackMappingTests {

    /// The `.vlc` tag is the whole point: a VLC `trackId` string can never be confused
    /// with an AVKit option index or a Jellyfin stream index.
    @Test("buildAudioTrack tags the id .vlc and carries name/language through",
          arguments: [("42", "English DTS", "en"), ("7", "Unknown", nil)] as [(String, String, String?)])
    func audioTrackMapping(id: String, name: String, language: String?) {
        let track = VLCKitEngine.buildAudioTrack(id: id, name: name, language: language)
        #expect(track.id == .vlc(id))
        #expect(track.id.avKitOptionIndex == nil)
        #expect(track.displayName == name)
        #expect(track.languageCode == language)
        #expect(track.isUnsupported == false)   // the default: only a known-bad codec flips it
    }

    /// The inventory carries the undecodable flag through to the app, which is what lets the
    /// menu grey the row instead of offering a pick that plays silence.
    @Test("buildAudioTrack carries the unsupported marking through")
    func audioTrackCarriesUnsupportedFlag() {
        let track = VLCKitEngine.buildAudioTrack(id: "4", name: "Japanese", language: "jpn",
                                                 isUnsupported: true)
        #expect(track.isUnsupported)
    }

    /// VLC's track API exposes no forced flag, so every subtitle it vends is unforced —
    /// forced-track handling exists only on the AVKit path.
    @Test("buildSubtitleTrack maps id/name/language and is never forced")
    func subtitleTrackMapping() {
        let track = VLCKitEngine.buildSubtitleTrack(id: "s1", name: "French ASS", language: "fr")
        #expect(track.id == .vlc("s1"))
        #expect(track.displayName == "French ASS")
        #expect(track.languageCode == "fr")
        #expect(track.isForced == false)
    }
}

/// 3000ms is AV1-software-decode runway (device-proven: at 2× a far seek empties a
/// 1000ms buffer faster than AV1 can refill it → macroblocking). The constraint is
/// DECODE-bound, so it stays for software and unknown codecs; a hardware-decoded codec
/// on a LAN SMB share refills faster than realtime and a shallower buffer just makes
/// seeks land sooner.
@Suite("VLCKitEngine — cache depth")
struct VLCKitEngineCacheDepthTests {

    @Test("cacheDepthMs", arguments: [
        ("SMB + hardware-decoded h264", "smb", VideoCodec.h264, 1500),
        ("SMB + hardware-decoded hevc", "smb", .hevc, 1500),
        ("SMB + software-decoded av1", "smb", .av1, 3000),
        ("SMB + software-decoded vp9", "smb", .vp9, 3000),
        ("SMB + unknown codec — assume the worst", "smb", nil, 3000),
        ("http + hardware-decoded h264", "http", .h264, 3000),
        ("https + unknown codec", "https", nil, 3000),
    ] as [(String, String?, VideoCodec?, Int)])
    func cacheDepth(label: String, scheme: String?, codec: VideoCodec?, expected: Int) {
        let hints = PlaybackHints.fixture(scheme: scheme, container: .mkv, video: codec, audio: nil)
        #expect(VLCKitEngine.cacheDepthMs(for: hints) == expected, "\(label)")
    }

    /// The shallow depth only ever applies to the SMB + hardware-decode pair; every
    /// other combination keeps the full runway.
    @Test("the shallow buffer is strictly narrower than the default runway")
    func shallowIsShallower() {
        let shallow = VLCKitEngine.cacheDepthMs(for: .fixture(scheme: "smb", container: .mkv, video: .h264))
        let runway = VLCKitEngine.cacheDepthMs(for: .fixture(scheme: "smb", container: .mkv, video: .av1))
        #expect(shallow < runway)
    }
}
