import Foundation
import Observation
import ParallaxCore

/// Backs Settings → Diagnostics: the saved runs and the retained-logging switch.
@Observable
@MainActor
public final class DiagnosticsModel {
    public private(set) var sessions: [DiagnosticsSession] = []
    /// Owned here once read: the switch changes only through `toggleLogging()`, so a reload of the
    /// runs never writes it back.
    public private(set) var isLoggingEnabled: Bool

    private let edge: DiagnosticsEdge

    init(edge: DiagnosticsEdge) {
        self.edge = edge
        isLoggingEnabled = edge.isEnabled()
    }

    /// What the screen's `.task` runs.
    public func reload() async {
        sessions = await edge.sessions()
    }

    public func toggleLogging() {
        isLoggingEnabled.toggle()
        edge.setEnabled(isLoggingEnabled)
    }

    public func deleteLogs() async {
        edge.clear()
        await reload()
    }
}
