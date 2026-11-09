import Foundation
import ParallaxCore
import ParallaxFileBrowseTestSupport
@testable import ParallaxFeatures
import ParallaxTestScaling
import Synchronization
import Testing

@MainActor
@Suite("Diagnostics settings", .scaledTimeLimit())
struct DiagnosticsModelTests {
    @Test("turning logging off while the saved runs load keeps it off once they land")
    func toggleDuringReloadSticks() async {
        let listing = AsyncGate(open: false)
        let logging = LoggingSwitch()
        let diagnostics = DiagnosticsModel(edge: .fake(
            sessions: { await listing.pass(); return [] },
            logging: logging
        ))
        let reloading = Task { await diagnostics.reload() }
        await listing.awaitArrivals()

        diagnostics.toggleLogging()
        await listing.open()
        await reloading.value

        #expect(!diagnostics.isLoggingEnabled)
        #expect(!logging.isOn)
    }

    @Test("leaving the handoff screen while the listener is still binding stops the server")
    func leavingMidStartStopsTheServer() async {
        let binding = AsyncGate(open: false)
        let server = RecordingHandoffServer(binding: binding)
        let handoff = DiagnosticsHandoffModel(edge: .fake(server: server))
        let screen = Task { await handoff.run() }
        await binding.awaitArrivals()

        screen.cancel()
        await binding.open()
        await screen.value

        #expect(await server.stops > 0)
        guard case .starting = handoff.phase else {
            Issue.record("the screen left mid-start but shows \(handoff.phase)")
            return
        }
    }
}

private final class LoggingSwitch: Sendable {
    private let state = Mutex(true)
    var isOn: Bool { state.withLock { $0 } }
    func set(_ value: Bool) { state.withLock { $0 = value } }
}

/// A handoff server whose `start()` parks on `binding`, then fails the way a listener torn down
/// mid-bind does.
private actor RecordingHandoffServer: DiagnosticsHandoffServing {
    private let binding: AsyncGate
    private(set) var stops = 0

    init(binding: AsyncGate) {
        self.binding = binding
    }

    func start() async throws -> DiagnosticsHandoffServer.Endpoint {
        await binding.pass()
        throw DiagnosticsHandoffServer.HandoffError.stopped
    }

    func waitUntilStopped() async {}

    func stop() async { stops += 1 }
}

private extension DiagnosticsEdge {
    static func fake(
        sessions: @escaping @Sendable () async -> [DiagnosticsSession] = { [] },
        logging: LoggingSwitch = LoggingSwitch(),
        server: any DiagnosticsHandoffServing = RecordingHandoffServer(binding: AsyncGate())
    ) -> DiagnosticsEdge {
        DiagnosticsEdge(
            sessions: sessions,
            isEnabled: { logging.isOn },
            setEnabled: { logging.set($0) },
            clear: {},
            export: { DiagnosticsExportFile(fileName: "diagnostics.txt", payload: Data()) },
            makeHandoffServer: { _ in server }
        )
    }
}
