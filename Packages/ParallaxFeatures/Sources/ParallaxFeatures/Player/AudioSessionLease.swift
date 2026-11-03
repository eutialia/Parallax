import Foundation
import Observation
import ParallaxPlayback

/// One player's hold on the shared audio session, and the only way that player reaches it.
///
/// The next player activates the same session, so a call from this one landing after that
/// activation is the defect: a late `deactivate()` silences the new player. The live session runs
/// each call `@concurrent`, nothing orders two that overlap, and several of the player's paths
/// call it (a start, its cancellation, a failed reload, the teardown), sometimes at once: a replay
/// can start while the start it replaced is still unwinding. So the lease counts what is in flight
/// instead of trusting any one path to be the last.
///
/// `isIdle` is what a closing player waits on before the next one may open.
@MainActor
@Observable
final class AudioSessionLease {
    private let session: any AudioSessionControlling
    private var inFlight = 0
    private var isActive = false

    init(_ session: any AudioSessionControlling) {
        self.session = session
    }

    /// Nothing in flight and nothing left active.
    var isIdle: Bool { inFlight == 0 && !isActive }

    func activate() async throws {
        inFlight += 1
        defer { inFlight -= 1 }
        try await session.activate()
        isActive = true
    }

    func deactivate() async {
        inFlight += 1
        defer { inFlight -= 1 }
        await session.deactivate()
        isActive = false
    }
}
