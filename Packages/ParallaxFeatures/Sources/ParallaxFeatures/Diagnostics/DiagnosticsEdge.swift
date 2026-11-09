import Foundation
import ParallaxCore

/// The retained diagnostics log and its LAN handoff, as Settings → Diagnostics reaches them: the
/// disk, `UserDefaults` and a listening socket.
public nonisolated struct DiagnosticsEdge: Sendable {
    /// Every retained run, newest first.
    public let sessions: @Sendable () async -> [DiagnosticsSession]
    public let isEnabled: @Sendable () -> Bool
    public let setEnabled: @Sendable (Bool) -> Void
    /// Deletes every retained run except the current one.
    public let clear: @Sendable () -> Void
    /// Every retained run as one file, read into memory.
    public let export: @Sendable () async throws -> DiagnosticsExportFile
    public let makeHandoffServer: @Sendable (DiagnosticsExportFile) -> any DiagnosticsHandoffServing

    public init(
        sessions: @escaping @Sendable () async -> [DiagnosticsSession],
        isEnabled: @escaping @Sendable () -> Bool,
        setEnabled: @escaping @Sendable (Bool) -> Void,
        clear: @escaping @Sendable () -> Void,
        export: @escaping @Sendable () async throws -> DiagnosticsExportFile,
        makeHandoffServer: @escaping @Sendable (DiagnosticsExportFile) -> any DiagnosticsHandoffServing
    ) {
        self.sessions = sessions
        self.isEnabled = isEnabled
        self.setEnabled = setEnabled
        self.clear = clear
        self.export = export
        self.makeHandoffServer = makeHandoffServer
    }

    /// `DiagnosticsLog` on this device, and a real listener for the handoff.
    ///
    /// The reads run detached: `sessions()` opens and scans every retained run for the crash marker,
    /// and the export re-reads and concatenates all of them — up to a few megabytes of file reads
    /// that would otherwise run on the main actor while the screen pushes, the same class of
    /// main-thread stall this feature exists to investigate.
    public static let live = DiagnosticsEdge(
        sessions: { await Task.detached(priority: .userInitiated) { DiagnosticsLog.sessions() }.value },
        isEnabled: { DiagnosticsLog.isEnabled },
        setEnabled: { DiagnosticsLog.isEnabled = $0 },
        clear: { DiagnosticsLog.clear() },
        export: {
            try await Task.detached(priority: .userInitiated) {
                let url = try DiagnosticsLog.exportReport()
                return DiagnosticsExportFile(fileName: url.lastPathComponent, payload: try Data(contentsOf: url))
            }.value
        },
        makeHandoffServer: { DiagnosticsHandoffServer(payload: $0.payload, fileName: $0.fileName) }
    )
}

public nonisolated struct DiagnosticsExportFile: Sendable {
    public let fileName: String
    public let payload: Data

    public init(fileName: String, payload: Data) {
        self.fileName = fileName
        self.payload = payload
    }
}

/// The handoff server as the screen drives it.
public nonisolated protocol DiagnosticsHandoffServing: Sendable {
    func start() async throws -> DiagnosticsHandoffServer.Endpoint
    func waitUntilStopped() async
    func stop() async
}

extension DiagnosticsHandoffServer: DiagnosticsHandoffServing {}
