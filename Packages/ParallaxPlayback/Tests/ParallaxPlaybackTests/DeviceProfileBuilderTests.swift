import Testing
import Foundation
import ParallaxCore
import ParallaxPlayback
import ParallaxPlaybackTestSupport

@Suite("DeviceProfileBuilder")
struct DeviceProfileBuilderTests {

    /// The profile a default (no-HDR, stereo) device produces — the shape 12 of these
    /// tests need before they can look at one field.
    private func defaultCaps() async -> DeviceCapabilities {
        await DeviceProfileBuilder(probe: FakeCapabilityProbe()).build()
    }

    // MARK: — The fixed AVPlayer whitelist comes from the matrix, not a second list

    /// Compared against `PlaybackCapabilityMatrix` rather than re-typed literals: the
    /// matrix suite owns *what* the lists contain, this suite owns *that the builder
    /// serializes them into the wire profile*. Re-typing them here would let the two
    /// drift apart with both suites still green.
    @Test("build() serializes the matrix's AVKit whitelists into the profile")
    func staticWhitelistsComeFromTheMatrix() async {
        let caps = await defaultCaps()
        #expect(Set(caps.supportedVideoCodecs) == PlaybackCapabilityMatrix.avKitVideoCodecs)
        #expect(Set(caps.supportedAudioCodecs) == PlaybackCapabilityMatrix.avKitAudioCodecs)
        #expect(Set(caps.supportedContainers) == PlaybackCapabilityMatrix.avKitContainers)
        #expect(Set(caps.preferredSubtitleFormats) == PlaybackCapabilityMatrix.avKitSubtitleFormats)
    }

    /// Wiring check for the VLC direct-play tier `DeviceProfileTranslator` reads
    /// downstream — the *values* are pinned by `PlaybackCapabilityMatrixTests`.
    @Test("build() wires the software tier straight from the matrix")
    func softwareTierComesFromTheMatrix() async {
        let caps = await defaultCaps()
        #expect(Set(caps.softwareVideoCodecs) == PlaybackCapabilityMatrix.softwareVideoCodecs)
        #expect(Set(caps.softwareAudioCodecs) == PlaybackCapabilityMatrix.softwareAudioCodecs)
        #expect(Set(caps.softwareContainers) == PlaybackCapabilityMatrix.softwareContainers)
    }

    @Test("build() declares a 4K UHD ceiling")
    func staticResolution() async {
        #expect(await defaultCaps().maxResolution == .uhd4K)
    }

    // MARK: — Probed fields propagate verbatim

    @Test("build() propagates the probe's HDR support", arguments: [
        HDRSupport.none,
        HDRSupport.hdr10,
        HDRSupport([.hdr10, .dolbyVision]),
        HDRSupport([.hdr10, .hdr10Plus, .dolbyVision]),
    ])
    func hdrPropagates(hdr: HDRSupport) async {
        let builder = DeviceProfileBuilder(probe: FakeCapabilityProbe(hdr: hdr))
        #expect(await builder.build().hdr == hdr)
    }

    @Test("build() propagates the probe's audio output", arguments: [
        AudioOutputCapability.stereo,
        .multichannel(channelCount: 6),
        .multichannel(channelCount: 8),
        .atmos,
    ])
    func audioOutputPropagates(output: AudioOutputCapability) async {
        let builder = DeviceProfileBuilder(probe: FakeCapabilityProbe(audioOutput: output))
        #expect(await builder.build().audioOutput == output)
    }

    // MARK: — Caching + invalidation

    @Test("a second build() returns the cache without re-probing")
    func cacheHit() async {
        let probe = CountingFakeCapabilityProbe()
        let builder = DeviceProfileBuilder(probe: probe)
        _ = await builder.build()
        _ = await builder.build()
        let count = await probe.callCount
        #expect(count == 1, "expected the probe to run once (cached), got \(count)")
    }

    @Test("invalidate() forces a re-probe on the next build()")
    func invalidateForcesRebuild() async {
        let probe = CountingFakeCapabilityProbe()
        let builder = DeviceProfileBuilder(probe: probe)
        _ = await builder.build()
        await builder.invalidate()
        _ = await builder.build()
        let count = await probe.callCount
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
        #expect(DeviceProfileBuilder.lowDataBitrateCeiling < DeviceProfileBuilder.lanBitrateCeiling)
    }

    @Test("a genuine constraint flip invalidates the cache")
    func constraintChangeInvalidates() async {
        let probe = CountingFakeCapabilityProbe()
        let builder = DeviceProfileBuilder(probe: probe)
        _ = await builder.build()
        await builder.setNetworkConstrained(true)
        _ = await builder.build()
        let count = await probe.callCount
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
        let count = await probe.callCount
        #expect(count == 1, "expected the repeat setNetworkConstrained(true) to be a no-op, got \(count)")
    }
}
