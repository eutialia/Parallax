import CoreMedia
import Foundation
import Testing
import ParallaxPlayback
import ParallaxTestScaling

/// One engine and the media it plays, as that engine's suite stands them up for the contract.
///
/// `AVKitEngine`'s media acts on its own. A fake has no media, so its stage publishes what
/// `AVKitEngine` publishes for the same file, and the contract holds the fake to it.
@MainActor
public protocol PlaybackEngineStage {
    var engine: any PlaybackEngine { get }
    /// 8 s of video and three subtitle renditions in this order: English, a forced-only
    /// French, German.
    func subtitledStream() async throws -> PlayableAsset
    /// A stream the engine opens and cannot play.
    func unplayableStream() -> PlayableAsset
    /// Runs after `load` and `play()`: whatever the loaded media does by itself.
    func mediaActs(on asset: PlayableAsset) async throws
    /// Parks every later `load` at the one place it suspends, until `releaseLoads()`.
    func holdLoads()
    func releaseLoads()
    /// How many loads are parked now.
    var parkedLoads: Int { get }
    func tearDown() async
}

/// What a player scenario relies on an engine to do, and so what a fake may not do differently.
public enum PlaybackEngineClause: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case loadStates
    case seekWhilePlaying
    case loadThrows
    case subtitleNumbering

    public var testDescription: String { rawValue }
}

/// The assertions every concrete `PlaybackEngine` must satisfy, kept apart from any one engine's
/// suite so a new engine runs the same checks.
@MainActor
public enum PlaybackEngineContract {

    public static func emitsIdleFirst(
        _ engine: any PlaybackEngine,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        var iterator = engine.state.makeAsyncIterator()
        let first = await iterator.next()
        guard case .idle = first?.state else {
            Issue.record("expected .idle, got \(String(describing: first))", sourceLocation: sourceLocation)
            return
        }
    }

    public static func teardownFinishesStream(
        _ engine: any PlaybackEngine,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        var iterator = engine.state.makeAsyncIterator()
        _ = await iterator.next()          // drain the buffered .idle
        await engine.teardown()
        // Any further buffered beats are allowed; the stream MUST terminate.
        while let value = await iterator.next() {
            if case .idle = value.state { continue }
            break
        }
        let terminal = await iterator.next()
        #expect(terminal == nil, sourceLocation: sourceLocation)
    }

    public static func holds<Stage: PlaybackEngineStage>(
        _ clause: PlaybackEngineClause,
        staging: () -> Stage
    ) async throws {
        switch clause {
        case .loadStates: try await loadStates(staging())
        case .seekWhilePlaying: try await seekWhilePlaying(staging())
        case .loadThrows:
            try await unplayableFailsOnTheStream(staging())
            try await supersededLoadIsCancelled(staging(), by: .teardown)
            try await supersededLoadIsCancelled(staging(), by: .load)
        case .subtitleNumbering: try await subtitleNumbering(staging())
        }
    }

    /// `.loading`, then `.ready`, both from the session `load` returned, and nothing from it
    /// before the `.loading`.
    private static func loadStates(_ stage: some PlaybackEngineStage) async throws {
        let record = BeatRecord(stage.engine)
        let asset = try await stage.subtitledStream()
        let opened = try await stage.engine.load(asset)
        await stage.engine.play()
        try await stage.mediaActs(on: asset)
        try await requireEventually({ record.states(of: opened).contains { $0.kind == "ready" } },
                                    "the stream never got ready", timeout: CITimeScale.seconds(15))

        #expect(opened != .none)
        let kinds = record.states(of: opened).map(\.kind)
        #expect(kinds.first == "loading", "\(kinds)")
        #expect(kinds.filter { $0 == "ready" }.count == 1, "\(kinds)")
        #expect(!kinds.contains("failed"), "\(kinds)")
        let foreign = record.beats.filter { $0.session != opened && $0.session != .none }
        #expect(foreign.isEmpty, "\(foreign.map(\.session))")
        record.stop()
        await stage.tearDown()
    }

    /// The first observed beat after a seek carries a clock at or past its target, and none
    /// before it does.
    private static func seekWhilePlaying(_ stage: some PlaybackEngineStage) async throws {
        let record = BeatRecord(stage.engine)
        let asset = try await stage.subtitledStream()
        let opened = try await stage.engine.load(asset)
        await stage.engine.play()
        try await stage.mediaActs(on: asset)
        try await requireEventually({ record.positions(of: opened).contains { $0.provenance == .observed && !$0.isBuffering } },
                                    "the stream never played", timeout: CITimeScale.seconds(15))

        let target = 5.0
        let mark = record.beats.count
        await stage.engine.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        try await requireEventually({ record.positions(of: opened, from: mark).contains { $0.provenance == .observed } },
                                    "nothing observed after the seek", timeout: CITimeScale.seconds(15))

        let afterSeek = record.positions(of: opened, from: mark)
        let firstObserved = try #require(afterSeek.first { $0.provenance == .observed })
        #expect(firstObserved.seconds >= target, "the seek landed at \(firstObserved.seconds): \(afterSeek)")
        record.stop()
        await stage.tearDown()
    }

    /// `load` returns for media that cannot play, and its failure arrives on the stream.
    private static func unplayableFailsOnTheStream(_ stage: some PlaybackEngineStage) async throws {
        let record = BeatRecord(stage.engine)
        let asset = stage.unplayableStream()
        let opened = try await stage.engine.load(asset)
        await stage.engine.play()
        try await stage.mediaActs(on: asset)
        try await requireEventually({ record.states(of: opened).contains { $0.kind == "failed" } },
                                    "the unplayable stream never failed", timeout: CITimeScale.seconds(15))

        let failures = record.states(of: opened).compactMap { state -> PlaybackError? in
            if case .failed(let error) = state { error } else { nil }
        }
        #expect(failures == [.assetNotPlayable])
        record.stop()
        await stage.tearDown()
    }

    enum Superseder { case teardown, load }

    /// A load that a teardown or another load overtakes while it is suspended throws
    /// `CancellationError`, the only error `load` throws.
    private static func supersededLoadIsCancelled(
        _ stage: some PlaybackEngineStage, by superseder: Superseder
    ) async throws {
        let asset = try await stage.subtitledStream()
        stage.holdLoads()
        let engine = stage.engine
        let first = Task { @MainActor in try await engine.load(asset) }
        try await requireEventually({ stage.parkedLoads == 1 }, "the load never suspended")
        let second: Task<PlaybackSessionID, any Error>?
        switch superseder {
        case .teardown:
            await engine.teardown()
            second = nil
        case .load:
            second = Task { @MainActor in try await engine.load(asset) }
            try await requireEventually({ stage.parkedLoads == 2 }, "the second load never suspended")
        }
        stage.releaseLoads()

        let outcome = await first.result
        #expect(throws: CancellationError.self, "superseded by \(superseder)") { try outcome.get() }
        if let second {
            let opened = try await second.value
            #expect(opened != .none)
        }
        await stage.tearDown()
    }

    /// Each offered subtitle keeps its option's index in the whole legible group, so the
    /// forced-only French, which is not offered, leaves a gap rather than shifting German down.
    private static func subtitleNumbering(_ stage: some PlaybackEngineStage) async throws {
        let record = BeatRecord(stage.engine)
        let asset = try await stage.subtitledStream()
        let opened = try await stage.engine.load(asset)
        await stage.engine.play()
        try await stage.mediaActs(on: asset)
        try await requireEventually({ record.inventory(of: opened) != nil }, "the stream never got ready",
                                    timeout: CITimeScale.seconds(15))

        // AVFoundation also offers machine translations into the host's preferred languages,
        // after the stream's own renditions.
        let own = Set(["en", "fr", "de"])
        let offered = try #require(record.inventory(of: opened)).subtitles
            .filter { own.contains($0.languageCode ?? "") }
        #expect(offered.map(\.id) == [.avKitOption(0), .avKitOption(2)], "\(offered)")
        #expect(offered.map(\.languageCode) == ["en", "de"])
        record.stop()
        await stage.tearDown()
    }
}

/// A subtitle rendition as the stream declares it, in its group's order.
public struct LegibleRendition: Sendable {
    public let displayName: String
    public let languageCode: String?
    public let isForcedOnly: Bool

    public init(displayName: String, languageCode: String?, isForcedOnly: Bool = false) {
        self.displayName = displayName
        self.languageCode = languageCode
        self.isForcedOnly = isForcedOnly
    }
}

public extension TrackInventory {
    /// The subtitles `AVKitEngine` offers for a legible group of `renditions`: each keeps its
    /// index in the group as its id, and a forced-only one is not offered.
    static func avKitSubtitles(_ renditions: [LegibleRendition]) -> TrackInventory {
        TrackInventory(audio: [], subtitles: renditions.enumerated()
            .filter { !$0.element.isForcedOnly }
            .map { index, rendition in
                SubtitleTrack(id: .avKitOption(index), displayName: rendition.displayName,
                              languageCode: rendition.languageCode, isForced: false)
            })
    }
}

/// Every beat an engine publishes, as it lands. One consumer, which is the stream's contract.
@MainActor
final class BeatRecord {
    private(set) var beats: [PlaybackBeat] = []
    private var task: Task<Void, Never>?

    init(_ engine: any PlaybackEngine) {
        let stream = engine.state
        task = Task { @MainActor [weak self] in
            for await beat in stream { self?.beats.append(beat) }
        }
    }

    func states(of session: PlaybackSessionID) -> [PlaybackState] {
        beats.filter { $0.session == session }.map(\.state)
    }

    func positions(of session: PlaybackSessionID, from mark: Int = 0) -> [PositionBeat] {
        beats.dropFirst(mark).filter { $0.session == session }.compactMap { PositionBeat($0.state) }
    }

    func inventory(of session: PlaybackSessionID) -> TrackInventory? {
        states(of: session).lazy.compactMap { state -> TrackInventory? in
            if case .ready(_, let tracks) = state { tracks } else { nil }
        }.first
    }

    func stop() { task?.cancel() }
}

private extension PlaybackState {
    var kind: String {
        switch self {
        case .idle: "idle"
        case .loading: "loading"
        case .ready: "ready"
        case .playing: "playing"
        case .paused: "paused"
        case .buffering: "buffering"
        case .ended: "ended"
        case .failed: "failed"
        }
    }
}
