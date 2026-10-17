import Testing
import Foundation
import ParallaxCore
import ParallaxPlayback
import ParallaxPlaybackTestSupport

@Suite("DeviceProfileBuilder")
struct DeviceProfileBuilderTests {

    // MARK: — The VLC tier is what AVPlayer leaves over

    static let withoutAV1 = AVPlayerSupport(
        containers: [.mp4, .mov, .hls], videoCodecs: [.h264, .hevc], audioCodecs: [.aac, .ac3, .eac3]
    )
    static let withAV1 = AVPlayerSupport(
        containers: [.mp4, .mov, .hls],
        videoCodecs: [.h264, .hevc, .av1],
        audioCodecs: [.aac, .ac3, .eac3, .flac, .opus]
    )

    @Test("build() carries the probed AVPlayer support", arguments: [withoutAV1, withAV1])
    func avPlayerSupportPropagates(support: AVPlayerSupport) async {
        let builder = DeviceProfileBuilder(probe: FakeCapabilityProbe(avPlayer: support))
        #expect(await builder.build().avPlayer == support)
    }

    /// The VLC tier rides the wire profile so servers direct-play VLC-only sources
    /// instead of transcoding them, and must never claim what AVPlayer plays: an
    /// h264/hevc VLC tier would lose HDR/DV/Atmos on premium MKV content.
    @Test("build() serializes the libvlc declaration minus AVPlayer's support as the VLC tier")
    func softwareTierIsVLCMinusAVPlayer() async {
        let without = await DeviceProfileBuilder(probe: FakeCapabilityProbe(avPlayer: Self.withoutAV1)).build()
        #expect(without.softwareVideoCodecs == [.av1, .mpeg2video, .vc1, .vp9])
        #expect(without.softwareAudioCodecs == [.dts, .flac, .mp3, .opus])
        #expect(without.softwareContainers == [.asf, .avi, .flac, .mkv, .mp3, .mpegps, .ts, .webm])

        let with = await DeviceProfileBuilder(probe: FakeCapabilityProbe(avPlayer: Self.withAV1)).build()
        #expect(with.softwareVideoCodecs == [.mpeg2video, .vc1, .vp9])
        #expect(with.softwareAudioCodecs == [.dts, .mp3])
        #expect(with.softwareContainers == [.asf, .avi, .flac, .mkv, .mp3, .mpegps, .ts, .webm])
    }

    @Test("build() declares a 4K UHD ceiling")
    func staticResolution() async {
        #expect(await DeviceProfileBuilder(probe: FakeCapabilityProbe()).build().maxResolution == .uhd4K)
    }

    // MARK: — Probed fields propagate verbatim

    @Test("build() propagates the probe's HDR support", arguments: [
        HDRSupport.none,
        HDRSupport.hdr10,
        HDRSupport.dolbyVision,
        HDRSupport([.hdr10, .dolbyVision]),
    ])
    func hdrPropagates(hdr: HDRSupport) async {
        let builder = DeviceProfileBuilder(probe: FakeCapabilityProbe(hdr: hdr))
        #expect(await builder.build().hdr == hdr)
    }

    // MARK: — Caching + invalidation

    @Test("a second build() returns the cache without re-probing")
    func cacheHit() async {
        let probe = CountingFakeCapabilityProbe()
        let builder = DeviceProfileBuilder(probe: probe)
        _ = await builder.build()
        _ = await builder.build()
        let count = probe.callCount
        #expect(count == 1, "expected the probe to run once (cached), got \(count)")
    }

    @Test("invalidate() forces a re-probe on the next build()")
    func invalidateForcesRebuild() async {
        let probe = CountingFakeCapabilityProbe()
        let builder = DeviceProfileBuilder(probe: probe)
        _ = await builder.build()
        await builder.invalidate()
        _ = await builder.build()
        let count = probe.callCount
        #expect(count == 2, "expected a re-probe after invalidate, got \(count)")
    }

    // MARK: — Low Data Mode bitrate clamp

    @Test("the bitrate ceiling follows the constrained-path signal", arguments: [
        (false, DeviceProfileBuilder.lanBitrateCeiling),
        (true, DeviceProfileBuilder.lowDataBitrateCeiling),
    ])
    func bitrateCeiling(constrained: Bool, expected: Bitrate) async {
        let builder = DeviceProfileBuilder(probe: FakeCapabilityProbe())
        await builder.setNetworkConstrained(constrained)
        #expect(await builder.build().maxBitrate == expected)
    }

    /// The two ceilings must stay distinct, or the clamp is a no-op and Low Data Mode
    /// would keep asking the server for 360 Mbps.
    @Test("the Low Data ceiling is genuinely lower than the LAN ceiling")
    func ceilingsDiffer() {
        #expect(DeviceProfileBuilder.lowDataBitrateCeiling.rawValue < DeviceProfileBuilder.lanBitrateCeiling.rawValue)
    }

    @Test("a genuine constraint flip invalidates the cache")
    func constraintChangeInvalidates() async {
        let probe = CountingFakeCapabilityProbe()
        let builder = DeviceProfileBuilder(probe: probe)
        _ = await builder.build()
        await builder.setNetworkConstrained(true)
        _ = await builder.build()
        let count = probe.callCount
        #expect(count == 2, "expected a re-probe after a real constraint change, got \(count)")
    }

    /// Callers forward every reachability update without checking first, so a repeat of
    /// the same value must not throw away a warm profile.
    @Test("re-setting the same constraint value keeps the cache warm")
    func sameConstraintValueDoesNotInvalidate() async {
        let probe = CountingFakeCapabilityProbe()
        let builder = DeviceProfileBuilder(probe: probe)
        await builder.setNetworkConstrained(true)
        _ = await builder.build()
        await builder.setNetworkConstrained(true)
        _ = await builder.build()
        let count = probe.callCount
        #expect(count == 1, "expected the repeat setNetworkConstrained(true) to be a no-op, got \(count)")
    }
}
