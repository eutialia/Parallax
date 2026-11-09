#if os(tvOS)
import ParallaxCore
import ParallaxFeatures
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
/// The server's lifetime is this screen's lifetime: `DiagnosticsHandoffModel.run()` serves for as
/// long as the `.task` runs, and leaving cancels it.
struct DiagnosticsHandoffView: View {
    @State private var model: DiagnosticsHandoffModel

    init(app: AppModel) {
        _model = State(initialValue: app.makeDiagnosticsHandoff())
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
        .task { await model.run() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
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
        switch model.phase {
        case .serving:
            "Both devices must be on the same network. This stops as soon as you leave this screen."
        default:
            "Both devices must be on the same network."
        }
    }
}
#endif
