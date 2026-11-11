import Testing
import ParallaxPlayback

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
}
