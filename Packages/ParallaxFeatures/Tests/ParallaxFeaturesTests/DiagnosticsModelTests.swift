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

    @Test("a listener that finishes binding after the handoff screen left is stopped and never shown")
    func leavingMidStartStopsTheServer() async {
        let binding = AsyncGate(open: false)
        let server = RecordingHandoffServer(binding: binding)
        let handoff = DiagnosticsHandoffModel(edge: .fake(server: server))
        let screen = Task { await handoff.run() }
        await binding.awaitArrivals()

        screen.cancel()
        await binding.open()
        await screen.value

        #expect(await !server.isListening)
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

/// A handoff server whose `start()` parks on `binding` and then binds regardless of any stop that
/// came first: the worst a listener can do to a screen that already left.
private actor RecordingHandoffServer: DiagnosticsHandoffServing {
    private let binding: AsyncGate
    private(set) var isListening = false

    init(binding: AsyncGate) {
        self.binding = binding
    }

    func start() async throws -> DiagnosticsHandoffServer.Endpoint {
        await binding.pass()
        isListening = true
        return DiagnosticsHandoffServer.Endpoint(url: URL(filePath: "/handoff"), hostAndPort: "host:1/token")
    }

    func waitUntilStopped() async {}

    func stop() async { isListening = false }
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
