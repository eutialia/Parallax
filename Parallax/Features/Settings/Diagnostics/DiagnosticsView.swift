import ParallaxCore
import SwiftUI
#if !os(tvOS)
import CoreTransferable
import UniformTypeIdentifiers
#endif

/// Settings → Diagnostics: the retained on-device log, browsable and exportable from the device that
/// wrote it.
///
/// **Why this is a shipping screen and not a DEBUG one.** The failures it exists for happen where a
/// debugger cannot go — an Apple TV that slept, dropped its Xcode session, and crashed on the wake.
/// A Debug-only screen would be unreachable in exactly the build people are running when it happens.
///
/// **Sharing differs per platform because the platforms differ.** iOS/iPadOS get the system share
/// sheet. tvOS has none — `ShareLink` is `@available(tvOS, unavailable)` and
/// `UIActivityViewController` is `__TVOS_PROHIBITED`, and there is no Files app, AirDrop or
/// pasteboard behind them — so it serves the file over the LAN instead and shows the address
/// (`DiagnosticsHandoffView`). The on-screen viewer is the fallback on both.
///
/// The VM-free shell: reads `DiagnosticsLog` and hands plain values to `DiagnosticsContentView`,
/// which is what the previews render.
struct DiagnosticsView: View {
    #if DEBUG
    @Environment(AppDependencies.self) private var deps
    #endif
    @State private var sessions: [DiagnosticsSession] = []
    @State private var isEnabled = DiagnosticsLog.isEnabled
    @State private var isConfirmingClear = false

    var body: some View {
        DiagnosticsContentView(
            sessions: sessions,
            isLoggingEnabled: isEnabled,
            onToggleLogging: {
                isEnabled.toggle()
                DiagnosticsLog.isEnabled = isEnabled
            },
            onDeleteLogs: { isConfirmingClear = true },
            onFlushSMBConnections: flushSMBConnections,
            onTriggerTestCrash: triggerTestCrash
        )
        #if !os(tvOS)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await reload() }
        .confirmationDialog(
            "Delete saved logs?", isPresented: $isConfirmingClear, titleVisibility: .visible
        ) {
            Button("Delete Logs", role: .destructive) {
                DiagnosticsLog.clear()
                Task { await reload() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every saved log except this run’s. Nothing else is affected.")
        }
    }

    /// Off the main thread on purpose. `View` is `@MainActor`, so a `.task` closure stays on it —
    /// and `sessions()` opens and scans EVERY retained run looking for the crash marker, which is up
    /// to a few megabytes of file reads and string splitting. Doing that on main would freeze the
    /// push into this screen: the same class of main-thread stall this whole feature exists to
    /// investigate, caused by the screen doing the investigating.
    private func reload() async {
        let loaded = await Task.detached(priority: .userInitiated) {
            (sessions: DiagnosticsLog.sessions(), isEnabled: DiagnosticsLog.isEnabled)
        }.value
        sessions = loaded.sessions
        isEnabled = loaded.isEnabled
    }

    /// Runs the foreground pool flush ON DEMAND, so the operation the post-resume watchdog kill
    /// hangs on can be reproduced without the browse-then-background-then-return dance.
    ///
    /// The real trigger fires only from a VISIBLE `SMBBrowseView` returning to the foreground, which
    /// makes it awkward to hit deliberately and impossible to hit repeatedly. This runs the identical
    /// closure, so the log gets the same `flushIdle` + `→/← disconnectShare` records with their
    /// elapsed times — which is what tells us whether those disconnects hang, with or without the
    /// watchdog actually firing. Debug builds only: it exists to test a hypothesis, not to be used.
    private var flushSMBConnections: (() -> Void)? {
        #if DEBUG
        return {
            Task { await deps.flushSMBConnections() }
        }
        #else
        return nil
        #endif
    }

    /// Faults on purpose, to prove the crash pipeline still works.
    ///
    /// `CrashSentinel` fails SILENTLY: if anything linked in replaces our signal dispositions, a real
    /// crash leaves a log that simply stops with no marker — which reads as "the app wasn't killed",
    /// the exact wrong conclusion. `recordCrashHandlerState()` reports that the handlers are
    /// installed, but only firing one proves the whole chain — handler, backtrace, unbuffered write,
    /// and the next launch flagging the session. Debug builds only.
    private var triggerTestCrash: (() -> Void)? {
        #if DEBUG
        return { AppDiagnostics.triggerTestCrash() }
        #else
        return nil
        #endif
    }
}

/// Pure, previewable presentation of the Diagnostics screen — the same split `SettingsContentView`
/// uses, so the layout (including the crash row, which is hard to produce on demand) renders in a
/// `#Preview` with mock sessions.
struct DiagnosticsContentView: View {
    let sessions: [DiagnosticsSession]
    let isLoggingEnabled: Bool
    let onToggleLogging: () -> Void
    let onDeleteLogs: () -> Void
    /// Debug-only probes; both nil in Release, where the section is absent entirely.
    var onFlushSMBConnections: (() -> Void)? = nil
    var onTriggerTestCrash: (() -> Void)? = nil

    var body: some View {
        SettingsScaffold(showsBrand: false) {
            shareSection
            sessionsSection
            settingsSection
            probesSection
        }
    }

    @ViewBuilder
    private var probesSection: some View {
        if onFlushSMBConnections != nil || onTriggerTestCrash != nil {
            SettingsGroup(
                title: "Probes",
                footer: "Flush runs the same connection teardown the app performs when it returns to the foreground, and records how long each disconnect takes. Test Crash faults on purpose to verify crash capture — the saved logs survive it, which is the point."
            ) {
                if let onFlushSMBConnections {
                    SettingsListRow(
                        systemImage: "bolt.horizontal",
                        title: "Flush SMB Connections",
                        action: onFlushSMBConnections
                    )
                }
                if let onTriggerTestCrash {
                    SettingsListRow(
                        systemImage: "exclamationmark.triangle",
                        title: "Trigger Test Crash",
                        action: onTriggerTestCrash
                    )
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var shareSection: some View {
        SettingsGroup(title: "Share", footer: Self.shareFooter) {
            #if os(tvOS)
            NavigationLink(value: SettingsView.Route.diagnosticsHandoff) {
                SettingsRowLabel(
                    systemImage: "wifi",
                    title: "Send to Another Device",
                    accessory: .chevron
                )
            }
            .tvListRowButton()
            #else
            ShareLink(item: DiagnosticsExport(), preview: SharePreview("Parallax Diagnostics")) {
                SettingsRowLabel(
                    systemImage: "square.and.arrow.up",
                    title: "Share Logs",
                    isAccent: true
                )
            }
            .buttonStyle(.plain)
            #endif
        }
    }

    private static var shareFooter: String {
        #if os(tvOS)
        "Serves the logs over your local network so you can open them on a phone or computer."
        #else
        "Exports every saved run as one text file. Server and share names are included; folder and file names, passwords and tokens are not."
        #endif
    }

    @ViewBuilder
    private var sessionsSection: some View {
        SettingsGroup(
            title: "Saved Runs",
            footer: sessions.isEmpty ? nil : "Newest first. The last \(DiagnosticsLog.retainedSessions) runs are kept."
        ) {
            if sessions.isEmpty {
                SettingsListRow(
                    systemImage: "doc.text",
                    title: "No Saved Logs",
                    value: isLoggingEnabled ? nil : "Logging off"
                )
            } else {
                ForEach(sessions) { session in
                    NavigationLink(value: SettingsView.Route.diagnosticsSession(session)) {
                        SettingsRowLabel(
                            systemImage: session.endedInCrash ? "exclamationmark.triangle" : "doc.text",
                            title: Self.title(for: session),
                            subtitle: Self.subtitle(for: session),
                            accessory: .chevron,
                            isDestructive: session.endedInCrash
                        )
                    }
                    .tvListRowButton()
                }
            }
        }
    }

    @ViewBuilder
    private var settingsSection: some View {
        SettingsGroup(
            title: "Settings",
            footer: "Logging records what the app was doing — connections, screens, and errors — so a crash can be explained afterwards."
        ) {
            SettingsListRow(
                systemImage: "text.append",
                title: "Save Logs on This Device",
                value: isLoggingEnabled ? "On" : "Off",
                action: onToggleLogging
            )
            SettingsListRow(
                systemImage: "trash",
                title: "Delete Saved Logs",
                role: .destructive,
                action: onDeleteLogs
            )
        }
    }

    // MARK: - Row text

    static func title(for session: DiagnosticsSession) -> String {
        let when = session.startedAt.formatted(date: .abbreviated, time: .shortened)
        return session.isCurrent ? "\(when) (this run)" : when
    }

    static func subtitle(for session: DiagnosticsSession) -> String {
        let size = Int64(session.byteCount).formatted(.byteCount(style: .file))
        return session.endedInCrash ? "Crashed · \(size)" : size
    }
}

#if !os(tvOS)
/// The export as a `Transferable` FILE, produced when the share is actually performed rather than
/// when the screen appears.
///
/// That laziness is the point: the current run keeps appending while this screen is open, so an
/// export prepared up front would stop just short of whatever the person is trying to report.
/// `FileRepresentation` is the documented way to defer preparation — see `ShareLink`'s note about
/// asynchronous content — and it also gives the share sheet a real file, which is what AirDrop, Mail
/// and Messages need in order to offer themselves at all.
private struct DiagnosticsExport: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { _ in
            SentTransferredFile(try DiagnosticsLog.exportReport())
        }
    }
}
#endif

// MARK: - Previews

#Preview("Diagnostics — with a crash") {
    NavigationStack {
        DiagnosticsContentView(
            sessions: [
                DiagnosticsSession(
                    id: "a", url: URL(fileURLWithPath: "/a"),
                    startedAt: .now, byteCount: 12_400, isCurrent: true, crashSummary: nil
                ),
                DiagnosticsSession(
                    id: "b", url: URL(fileURLWithPath: "/b"),
                    startedAt: .now.addingTimeInterval(-3600), byteCount: 88_100, isCurrent: false,
                    crashSummary: "*** PARALLAX CRASH *** signal=SIGSEGV code=2 address=0x1"
                ),
                DiagnosticsSession(
                    id: "c", url: URL(fileURLWithPath: "/c"),
                    startedAt: .now.addingTimeInterval(-86_400), byteCount: 4_200, isCurrent: false,
                    crashSummary: nil
                ),
            ],
            isLoggingEnabled: true,
            onToggleLogging: {},
            onDeleteLogs: {}
        )
    }
    .background(BackgroundField.style)
}

#Preview("Diagnostics — empty, logging off") {
    NavigationStack {
        DiagnosticsContentView(
            sessions: [],
            isLoggingEnabled: false,
            onToggleLogging: {},
            onDeleteLogs: {}
        )
    }
    .background(BackgroundField.style)
}
