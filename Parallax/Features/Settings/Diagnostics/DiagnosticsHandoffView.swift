#if os(tvOS)
import ParallaxCore
import SwiftUI

/// tvOS's substitute for the share sheet it doesn't have: the app serves the logs over the local
/// network and puts the address on the television.
///
/// An Apple TV has no share sheet, no Files app, no AirDrop and no pasteboard, so there is no system
/// path for handing a file to a person. Showing an address they can type into a browser on a phone
/// is the shortest one left — which is also why `DiagnosticsHandoffServer` answers on every path and
/// carries no token in the URL: every extra character is one somebody has to read off a TV and type
/// on a phone.
///
/// The server's lifetime is this screen's lifetime. Leaving stops it.
struct DiagnosticsHandoffView: View {
    @State private var phase: Phase = .starting
    @State private var server: DiagnosticsHandoffServer?

    private enum Phase {
        case starting
        case serving(DiagnosticsHandoffServer.Endpoint)
        case failed(String)
    }

    var body: some View {
        SettingsScaffold(showsBrand: false) {
            SettingsGroup(title: "Send to Another Device", footer: footer) {
                // EVERY state of this screen is static text — an address to read, a spinner label,
                // an error. That makes it a zero-focusable tvOS screen, where focus never enters and
                // Menu has no in-app responder to pop the stack, so it suspends the app instead (the
                // empty-SMB-folder trap). The invisible focus target is what keeps Back working.
                content
                    .tvFocusableSurface()
            }
        }
        .task { await start() }
        .onDisappear {
            // The captured server, not `self.server`: this view's state may already be torn down by
            // the time the detached stop runs.
            let server = self.server
            self.server = nil
            Task { await server?.stop() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .starting:
            SettingsListRow(systemImage: "wifi", title: "Starting…")
        case .serving(let endpoint):
            VStack(alignment: .leading, spacing: Space.s12) {
                Text("Open this address in a browser on your phone or computer:")
                    .font(.rowSubtitle)
                    .foregroundStyle(Color.secondaryLabel)
                // The `http://` is shown, not trimmed for brevity: a bare `host:port` typed into
                // Safari's unified address bar can be taken for a search term, and a search result
                // is a much worse dead end than seven extra characters.
                Text("http://\(endpoint.hostAndPort)")
                    .font(.system(size: 46, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.label)
                    .textCase(.lowercase)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SettingsMetrics.rowHInset)
        case .failed(let message):
            SettingsListRow(systemImage: "exclamationmark.triangle", title: message, role: .destructive)
        }
    }

    private var footer: String {
        switch phase {
        case .serving:
            "Both devices must be on the same network. This stops as soon as you leave this screen."
        default:
            "Both devices must be on the same network."
        }
    }

    private func start() async {
        do {
            // Detached, not just "outside `init`": `View` is `@MainActor`, so building the export
            // here directly would read and re-concatenate every saved run ON THE MAIN THREAD while
            // the push animates.
            let (url, payload) = try await Task.detached(priority: .userInitiated) {
                let url = try DiagnosticsLog.exportReport()
                return (url, try Data(contentsOf: url))
            }.value
            // The export can outlive the screen — nothing above is cancellation-aware — and binding
            // a listener after the view is gone would leave a server with no `onDisappear` left to
            // stop it, breaking this file's promise that the URL lives exactly as long as the screen.
            try Task.checkCancellation()
            let server = DiagnosticsHandoffServer(payload: payload, fileName: url.lastPathComponent)
            self.server = server
            let endpoint = try await server.start()
            guard !Task.isCancelled else {
                self.server = nil
                await server.stop()
                return
            }
            phase = .serving(endpoint)
        } catch is CancellationError {
            // Left the screen mid-start; `onDisappear` owns teardown from here.
        } catch DiagnosticsHandoffServer.HandoffError.offNetwork {
            phase = .failed("Not connected to a network")
        } catch {
            phase = .failed("Couldn’t start: \(error.localizedDescription)")
        }
    }
}
#endif
