import Testing
import Foundation
import ParallaxCore
@testable import ParallaxPlayback

@Suite("SubtitleResolver")
struct SubtitleResolverTests {

    private func externalSub(format: SubtitleFormat, isForced: Bool = false) -> ExternalSubtitle {
        ExternalSubtitle(
            url: URL(string: "https://jf.example.com/Videos/1/Subtitles/0/Stream.srt?api_key=abc")!,
            format: format, languageCode: "en", isForced: isForced
        )
    }

    @Test("VLC + SRT external → vlcSlave with enforce=false")
    func vlcSRTExternal() {
        let sub = externalSub(format: .srt)
        let delivery = SubtitleResolver.resolve(subtitle: sub, engine: .vlcKit)
        if case .vlcSlave(let url, let enforce) = delivery {
            #expect(url == sub.url); #expect(enforce == false)
        } else { Issue.record("Expected .vlcSlave, got \(delivery)") }
    }

    @Test("VLC + forced SRT → vlcSlave with enforce=true")
    func vlcForcedSRTExternal() {
        let sub = externalSub(format: .srt, isForced: true)
        let delivery = SubtitleResolver.resolve(subtitle: sub, engine: .vlcKit)
        if case .vlcSlave(_, let enforce) = delivery { #expect(enforce == true) }
        else { Issue.record("Expected .vlcSlave, got \(delivery)") }
    }

    @Test("VLC + ASS external → vlcSlave")
    func vlcASSExternal() {
        let delivery = SubtitleResolver.resolve(subtitle: externalSub(format: .ass), engine: .vlcKit)
        if case .vlcSlave = delivery {} else { Issue.record("Expected .vlcSlave for ASS, got \(delivery)") }
    }

    @Test("VLC + VTT external → vlcSlave")
    func vlcVTTExternal() {
        let delivery = SubtitleResolver.resolve(subtitle: externalSub(format: .vtt), engine: .vlcKit)
        if case .vlcSlave = delivery {} else { Issue.record("Expected .vlcSlave for VTT, got \(delivery)") }
    }

    @Test("VLC + PGS external → vlcSlave")
    func vlcPGSExternal() {
        let delivery = SubtitleResolver.resolve(subtitle: externalSub(format: .pgs), engine: .vlcKit)
        if case .vlcSlave = delivery {} else { Issue.record("Expected .vlcSlave for PGS, got \(delivery)") }
    }

    @Test("VLC + VobSub external → vlcSlave")
    func vlcVobSubExternal() {
        let delivery = SubtitleResolver.resolve(subtitle: externalSub(format: .vobsub), engine: .vlcKit)
        if case .vlcSlave = delivery {} else { Issue.record("Expected .vlcSlave for VobSub, got \(delivery)") }
    }

    @Test("AVKit + SRT external → avKitSidecar")
    func avKitSRTExternal() {
        let sub = externalSub(format: .srt)
        let delivery = SubtitleResolver.resolve(subtitle: sub, engine: .avKit)
        if case .avKitSidecar(let url) = delivery { #expect(url == sub.url) }
        else { Issue.record("Expected .avKitSidecar for SRT, got \(delivery)") }
    }

    @Test("AVKit + VTT external → avKitSidecar")
    func avKitVTTExternal() {
        let delivery = SubtitleResolver.resolve(subtitle: externalSub(format: .vtt), engine: .avKit)
        if case .avKitSidecar = delivery {} else { Issue.record("Expected .avKitSidecar for VTT, got \(delivery)") }
    }

    @Test("AVKit + ASS external → unsupported")
    func avKitASSUnsupported() {
        let delivery = SubtitleResolver.resolve(subtitle: externalSub(format: .ass), engine: .avKit)
        if case .unsupported = delivery {} else { Issue.record("Expected .unsupported for ASS, got \(delivery)") }
    }

    @Test("AVKit + PGS external → unsupported")
    func avKitPGSUnsupported() {
        let delivery = SubtitleResolver.resolve(subtitle: externalSub(format: .pgs), engine: .avKit)
        if case .unsupported = delivery {} else { Issue.record("Expected .unsupported for PGS, got \(delivery)") }
    }

    @Test("AVKit + VobSub external → unsupported")
    func avKitVobSubUnsupported() {
        let delivery = SubtitleResolver.resolve(subtitle: externalSub(format: .vobsub), engine: .avKit)
        if case .unsupported = delivery {} else { Issue.record("Expected .unsupported for VobSub, got \(delivery)") }
    }

    @Test("resolveAll maps every subtitle in a list")
    func resolveAll() {
        let subs = [externalSub(format: .srt), externalSub(format: .ass)]
        let deliveries = SubtitleResolver.resolveAll(subtitles: subs, engine: .vlcKit)
        #expect(deliveries.count == 2)
        if case .vlcSlave = deliveries[0] {} else { Issue.record("idx0 not vlcSlave") }
        if case .vlcSlave = deliveries[1] {} else { Issue.record("idx1 not vlcSlave") }
    }

    @Test("resolveAll returns empty for empty input")
    func resolveAllEmpty() {
        #expect(SubtitleResolver.resolveAll(subtitles: [], engine: .vlcKit).isEmpty)
    }
}
