import Testing
import ParallaxCore
import ParallaxPlayback
import ParallaxPlaybackTestSupport

@Suite("DirectPlay.verdict")
struct DirectPlayVerdictTests {

    private func clean(
        _ container: Container? = .mp4,
        video: ProbedCodec<VideoCodec> = .known(.h264),
        audio: ProbedCodec<[AudioCodec]> = .known([.aac]),
        isComplete: Bool = true,
        hazards: Set<AVPlayerHazard> = []
    ) -> MediaProbeResult {
        MediaProbeResult(
            container: container, videoCodec: video, audioCodecs: audio,
            isComplete: isComplete, avPlayerHazards: hazards
        )
    }

    @Test("a complete h264/aac file in an AVPlayer container plays direct", arguments: [Container.mp4, .mov])
    func directPlay(container: Container) {
        #expect(DirectPlay.verdict(for: clean(container), support: .baseline) == .direct(container))
    }

    @Test("a video codec plays direct only where this device's AVPlayer decodes it")
    func videoCodecFollowsSupport() {
        let probe = clean(video: .known(.av1))
        let withAV1 = AVPlayerSupport(containers: [.mp4], videoCodecs: [.h264, .av1], audioCodecs: [.aac])
        #expect(DirectPlay.verdict(for: probe, support: withAV1) == .direct(.mp4))
        #expect(DirectPlay.verdict(for: probe, support: .baseline) == .unplayable(.videoCodec(.av1)))
    }

    @Test("an incomplete file is unplayable however clean its codecs are")
    func incompleteFile() {
        #expect(DirectPlay.verdict(for: clean(isComplete: false), support: .baseline) == .unplayable(.incompleteFile))
    }

    @Test("a container AVPlayer cannot open, or one the probe could not identify", arguments: [Container?.none, .mkv, .asf])
    func container(container: Container?) {
        #expect(DirectPlay.verdict(for: clean(container), support: .baseline) == .unplayable(.container(container)))
    }

    @Test("a video codec AVPlayer cannot decode, or one the probe could not identify", arguments: [
        (ProbedCodec<VideoCodec>.known(.vp9), VideoCodec?.some(.vp9)),
        (.unknown, nil),
    ])
    func videoCodec(video: ProbedCodec<VideoCodec>, reported: VideoCodec?) {
        #expect(DirectPlay.verdict(for: clean(video: video), support: .baseline) == .unplayable(.videoCodec(reported)))
    }

    @Test("any audio track AVPlayer cannot decode, or one the probe could not identify", arguments: [
        (ProbedCodec<[AudioCodec]>.known([.dts]), AudioCodec?.some(.dts)),
        (.known([.aac, .dts]), .some(.dts)),
        (.unknown, nil),
    ])
    func audioCodec(audio: ProbedCodec<[AudioCodec]>, reported: AudioCodec?) {
        #expect(DirectPlay.verdict(for: clean(audio: audio), support: .baseline) == .unplayable(.audioCodec(reported)))
    }

    @Test("any proven AVPlayer hazard keeps an otherwise clean file off direct play", arguments: [
        Set<AVPlayerHazard>([.decodeOrderTimestamps]),
        [.interlacedVideo],
        [.inBandParameterSets, .missingParameterSets],
    ])
    func directHazards(hazards: Set<AVPlayerHazard>) {
        #expect(DirectPlay.verdict(for: clean(hazards: hazards), support: .baseline) == .unplayable(.directHazards(hazards)))
    }
}
