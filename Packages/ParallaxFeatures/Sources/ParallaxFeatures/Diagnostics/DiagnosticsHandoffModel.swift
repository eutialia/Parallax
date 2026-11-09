import Foundation
import Observation
import ParallaxCore

/// Backs tvOS's Send to Another Device screen: serves the diagnostics export over the LAN for as
/// long as `run()` runs, which is as long as the screen is up.
@Observable
@MainActor
public final class DiagnosticsHandoffModel {
    public enum Phase {
        case starting
        case serving(DiagnosticsHandoffServer.Endpoint)
        case failed(String)
    }

    public private(set) var phase = Phase.starting

    private let edge: DiagnosticsEdge

    init(edge: DiagnosticsEdge) {
        self.edge = edge
    }

    /// What the screen's `.task` runs. Cancelling it, the screen going away, stops the server in
    /// whichever step it has reached: the URL lives exactly as long as the screen.
    public func run() async {
        do {
            let export = try await edge.export()
            try Task.checkCancellation()
            let server = edge.makeHandoffServer(export)
            await serve(server)
            await server.stop()
        } catch where Task.isCancelled {
        } catch {
            phase = Self.failure(error)
        }
    }

    private func serve(_ server: any DiagnosticsHandoffServing) async {
        do {
            let endpoint = try await withTaskCancellationHandler {
                try await server.start()
            } onCancel: {
                Task { await server.stop() }
            }
            guard !Task.isCancelled else { return }
            phase = .serving(endpoint)
            await withTaskCancellationHandler {
                await server.waitUntilStopped()
            } onCancel: {
                Task { await server.stop() }
            }
            // Only a stop with the screen still up means the listener died and the address on
            // screen leads nowhere.
            if !Task.isCancelled { phase = .failed("Lost the network connection") }
        } catch where Task.isCancelled {
        } catch {
            phase = Self.failure(error)
        }
    }

    private static func failure(_ error: any Error) -> Phase {
        if error as? DiagnosticsHandoffServer.HandoffError == .offNetwork {
            .failed("Not connected to a network")
        } else {
            .failed("Couldn’t start: \(error.localizedDescription)")
        }
    }
}
