import Foundation
import AVFoundation
import CoreMedia
import Testing
@testable import ParallaxPlayback

@Suite("AVKitEngine")
@MainActor
struct AVKitEngineTests {

    @Test("Declares the AVKit id and all-true capabilities")
    func identityAndCapabilities() {
        let engine = AVKitEngine()
        #expect(engine.id == .avKit)
        #expect(engine.capabilities == PlaybackEngineCapabilities(
            supportsPiP: true, supportsVideoAirPlay: true, supportsNowPlayingIntegration: true
        ))
    }

    /// The app sets `AVPlayerViewController.player` through this seam, so the hosting
    /// property must vend the very instance the engine drives — not a fresh one.
    @Test("Conforms to AVPlayerHosting and vends the AVPlayer it drives")
    func hostsAnAVPlayer() {
        let engine = AVKitEngine()
        let hosting: any AVPlayerHosting = engine
        #expect(hosting.avPlayer === engine.avPlayer)
    }
}

/// The engine-agnostic half of the `PlaybackEngine` stream contract, run against both
/// concrete engines. Previously duplicated verbatim in `AVKitEngineTests` and
/// `VLCKitEngineTests`.
@Suite("PlaybackEngine stream contract")
@MainActor
struct PlaybackEngineStreamContractTests {

    enum EngineKind: String, CaseIterable, CustomTestStringConvertible {
        case avKit, vlcKit
        var testDescription: String { rawValue }

        @MainActor func make() -> any PlaybackEngine {
            switch self {
            case .avKit: AVKitEngine()
            case .vlcKit: VLCKitEngine()
            }
        }
    }

    @Test("the state stream is pre-seeded with .idle", arguments: EngineKind.allCases)
    func emitsIdleFirst(kind: EngineKind) async {
        let engine = kind.make()
        var iterator = engine.state.makeAsyncIterator()
        let first = await iterator.next()
        guard case .idle = first else {
            Issue.record("expected .idle, got \(String(describing: first))")
            return
        }
    }

    @Test("teardown finishes the state stream so consumers' for-await loops end",
          arguments: EngineKind.allCases)
    func teardownFinishesStream(kind: EngineKind) async {
        let engine = kind.make()
        var iterator = engine.state.makeAsyncIterator()
        _ = await iterator.next()          // drain the buffered .idle
        await engine.teardown()
        // Any further buffered beats are allowed; the stream MUST terminate.
        while let value = await iterator.next() {
            if case .idle = value { continue }
            break
        }
        let terminal = await iterator.next()
        #expect(terminal == nil)
    }

    @Test("the engine id matches the kind that built it", arguments: EngineKind.allCases)
    func reportsItsOwnID(kind: EngineKind) {
        let expected: PlaybackEngineID = kind == .avKit ? .avKit : .vlcKit
        #expect(kind.make().id == expected)
    }
}

/// `redactedTail` is the only thing that ever writes an HLS resource URI into a log,
/// and the api_key rides in that URI's query — so dropping the query is a security
/// contract, not cosmetics.
@Suite("AVKitEngine — HLS error-log redaction")
@MainActor
struct AVKitLogRedactionTests {

    @Test("keeps the trailing two path components and drops the query", arguments: [
        ("https://jf.example.com/Videos/abc/main.m3u8?api_key=SECRET", "abc/main.m3u8"),
        ("https://jf.example.com/Videos/abc/hls1/main/123.mp4?api_key=SECRET&x=1", "main/123.mp4"),
        ("https://jf.example.com/master.m3u8", "master.m3u8"),
    ])
    func redactsTail(uri: String, expected: String) {
        let tail = AVKitEngine.redactedTail(of: uri)
        #expect(tail == expected)
        #expect(tail?.contains("SECRET") == false)
        #expect(tail?.contains("?") == false)
    }

    @Test("returns nil when there is no path to report", arguments: [
        "https://jf.example.com",
        "https://jf.example.com/",
    ])
    func nilWithoutPath(uri: String) {
        #expect(AVKitEngine.redactedTail(of: uri) == nil)
    }
}
