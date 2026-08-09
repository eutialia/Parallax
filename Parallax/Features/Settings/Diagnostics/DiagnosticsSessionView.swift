import ParallaxCore
import SwiftUI

/// One saved run's log, on screen. The fallback that always works: no network, no share sheet, no
/// second device — just the text, on whatever the app is running on.
///
/// It leads with the crash line when there is one, because that is the only reason anybody opens
/// this screen in a hurry.
struct DiagnosticsSessionView: View {
    let session: DiagnosticsSession

    @State private var text = ""

    var body: some View {
        SettingsScaffold(showsBrand: false, scrolls: false) {
            if let crash = session.crashSummary {
                SettingsGroup(title: "Crash") {
                    Text(crash)
                        .font(.rowSubtitle)
                        .monospaced()
                        .foregroundStyle(Color.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(SettingsMetrics.rowHInset)
                }
            }
            SettingsGroup(title: "Log") {
                logBody
            }
        }
        #if !os(tvOS)
        .navigationTitle(DiagnosticsContentView.title(for: session))
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Detached because `View` is `@MainActor`: reading a session file can be half a megabyte,
        // and on main that is a stalled push rather than a slow one.
        .task {
            text = await Task.detached(priority: .userInitiated) {
                DiagnosticsLog.text(of: session)
            }.value
        }
    }

    @ViewBuilder
    private var logBody: some View {
        #if os(tvOS)
        // tvOS `Text` is never focusable, so a long log would have no focus target and the remote
        // could not scroll it — `FocusableScrollText` is the shared fix (same one the licence pages
        // use), which is also why the scaffold above runs with `scrolls: false`.
        FocusableScrollText(text: text, textStyle: .caption1, design: .monospaced, textColor: .label)
            .frame(height: 720)
            .padding(SettingsMetrics.rowHInset)
        #else
        ScrollView {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.label)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SettingsMetrics.rowHInset)
        }
        .frame(maxHeight: 520)
        #endif
    }
}
