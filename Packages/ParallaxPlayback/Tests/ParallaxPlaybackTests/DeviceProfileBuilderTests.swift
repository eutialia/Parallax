import Testing
import Foundation
import ParallaxCore
import ParallaxPlayback
import ParallaxPlaybackTestSupport

@Suite("DeviceProfileBuilder")
struct DeviceProfileBuilderTests {

    // MARK: - Static whitelist

    @Test("build() populates the fixed AVPlayer video-codec whitelist")
    func staticVideoCodecs() async {
        let probe = FakeCapabilityProbe()
        let builder = DeviceProfileBuilder(probe: probe)
        let caps = await builder.build()
        #expect(caps.supportedVideoCodecs.sorted(by: { $0.rawValue < $1.rawValue }) ==
                [VideoCodec.h264, .hevc].sorted(by: { $0.rawValue < $1.rawValue }))
    }

    @Test("build() populates the fixed AVPlayer audio-codec whitelist")
    func staticAudioCodecs() async {
        let probe = FakeCapabilityProbe()
        let builder = DeviceProfileBuilder(probe: probe)
        let caps = await builder.build()
        let expected: Set<AudioCodec> = [.aac, .ac3, .eac3, .mp3]
        let actual = Set(caps.supportedAudioCodecs)
        #expect(actual == expected)
    }

    @Test("build() populates the fixed AVPlayer container whitelist")
    func staticContainers() async {
        let probe = FakeCapabilityProbe()
        let builder = DeviceProfileBuilder(probe: probe)
        let caps = await builder.build()
        let expected: Set<Container> = [.mp4, .mov, .hls]
        let actual = Set(caps.supportedContainers)
        #expect(actual == expected)
    }

    @Test("build() sets maxResolution to UHD 4K")
    func staticResolution() async {
        let probe = FakeCapabilityProbe()
        let builder = DeviceProfileBuilder(probe: probe)
        let caps = await builder.build()
        #expect(caps.maxResolution == .uhd4K)
    }

    @Test("build() sets maxBitrate to 120 Mbps sentinel")
    func staticBitrate() async {
        let probe = FakeCapabilityProbe()
        let builder = DeviceProfileBuilder(probe: probe)
        let caps = await builder.build()
        #expect(caps.maxBitrate == .megabits(120))
    }

    @Test("build() sets preferred subtitle formats to [.vtt, .srt]")
    func staticSubtitleFormats() async {
        let probe = FakeCapabilityProbe()
        let builder = DeviceProfileBuilder(probe: probe)
        let caps = await builder.build()
        #expect(Set(caps.preferredSubtitleFormats) == [.vtt, .srt])
    }

    @Test("build() populates softwareVideoCodecs from the matrix")
    func buildPopulatesSoftwareVideoCodecs() async {
        let probe = FakeCapabilityProbe()
        let builder = DeviceProfileBuilder(probe: probe)
        let caps = await builder.build()
        #expect(Set(caps.softwareVideoCodecs) == PlaybackCapabilityMatrix.softwareVideoCodecs)
    }

    @Test("build() populates softwareAudioCodecs from the matrix")
    func buildPopulatesSoftwareAudioCodecs() async {
        let probe = FakeCapabilityProbe()
        let builder = DeviceProfileBuilder(probe: probe)
        let caps = await builder.build()
        #expect(Set(caps.softwareAudioCodecs) == PlaybackCapabilityMatrix.softwareAudioCodecs)
    }

    @Test("build() populates softwareContainers from the matrix")
    func buildPopulatesSoftwareContainers() async {
        let probe = FakeCapabilityProbe()
        let builder = DeviceProfileBuilder(probe: probe)
        let caps = await builder.build()
        #expect(Set(caps.softwareContainers) == PlaybackCapabilityMatrix.softwareContainers)
    }

    // MARK: - Dynamic: HDR permutations

    @Test("build() reflects .none when probe returns no HDR support")
    func hdrNone() async {
        let probe = FakeCapabilityProbe(hdr: .none)
        let builder = DeviceProfileBuilder(probe: probe)
        let caps = await builder.build()
        #expect(caps.hdr == .none)
    }

    @Test("build() reflects .hdr10 when probe returns hdr10")
    func hdrHDR10() async {
        let probe = FakeCapabilityProbe(hdr: .hdr10)
        let builder = DeviceProfileBuilder(probe: probe)
        let caps = await builder.build()
        #expect(caps.hdr == .hdr10)
    }

    @Test("build() reflects [.hdr10, .dolbyVision] when probe returns both")
    func hdrBoth() async {
        let probe = FakeCapabilityProbe(hdr: [.hdr10, .dolbyVision])
        let builder = DeviceProfileBuilder(probe: probe)
        let caps = await builder.build()
        #expect(caps.hdr.contains(.hdr10))
        #expect(caps.hdr.contains(.dolbyVision))
    }

    // MARK: - Dynamic: audio-output permutations

    @Test("build() reflects .stereo when probe returns stereo")
    func audioStereo() async {
        let probe = FakeCapabilityProbe(audioOutput: .stereo)
        let builder = DeviceProfileBuilder(probe: probe)
        let caps = await builder.build()
        #expect(caps.audioOutput == .stereo)
    }

    @Test("build() reflects .multichannel(6) when probe returns 5.1")
    func audioMultichannel() async {
        let probe = FakeCapabilityProbe(audioOutput: .multichannel(channelCount: 6))
        let builder = DeviceProfileBuilder(probe: probe)
        let caps = await builder.build()
        if case .multichannel(let ch) = caps.audioOutput {
            #expect(ch == 6)
        } else {
            Issue.record("Expected .multichannel(6), got \(caps.audioOutput)")
        }
    }

    // MARK: - Caching + invalidate

    @Test("build() returns cached result on second call without re-probing")
    func cacheHit() async {
        let probe = CountingFakeCapabilityProbe(hdr: .none, audioOutput: .stereo)
        let builder = DeviceProfileBuilder(probe: probe)
        _ = await builder.build()
        _ = await builder.build()
        let count = await probe.callCount
        #expect(count == 1, "Expected probe called once (cached), got \(count)")
    }

    @Test("invalidate() forces a re-probe on the next build()")
    func invalidateForcesRebuild() async {
        let probe = CountingFakeCapabilityProbe(hdr: .none, audioOutput: .stereo)
        let builder = DeviceProfileBuilder(probe: probe)
        _ = await builder.build()
        await builder.invalidate()
        _ = await builder.build()
        let count = await probe.callCount
        #expect(count == 2, "Expected probe called twice after invalidate, got \(count)")
    }
}

// A variant of FakeCapabilityProbe that counts how many times it is called.
// Defined here (file-private to the test file effectively, but @testable is fine)
// rather than in the Fakes/ folder because it's only used in this suite.
// `@MainActor` (not an `actor`) so the call count increments synchronously
// inside `hdrSupport()`. The earlier `actor` version recorded each call via a
// fire-and-forget `Task { await recordCall() }`, which raced the test's
// `await probe.callCount` read and failed non-deterministically under parallel
// test execution. `DeviceProfileBuilder.build()` awaits the `@MainActor`
// `hdrSupport()` before it returns, so by the time the test reads `callCount`
// the increment has already landed — fully deterministic, no extra Task.
@MainActor
final class CountingFakeCapabilityProbe: CapabilityProbe {
    private let stubbedHDR: HDRSupport
    private let stubbedAudioOutput: AudioOutputCapability
    private(set) var callCount: Int = 0

    nonisolated init(hdr: HDRSupport, audioOutput: AudioOutputCapability) {
        self.stubbedHDR = hdr
        self.stubbedAudioOutput = audioOutput
    }

    func hdrSupport() -> HDRSupport {
        callCount += 1
        return stubbedHDR
    }

    nonisolated func audioOutput() -> AudioOutputCapability {
        stubbedAudioOutput
    }
}
