import SwiftUI

/// Add-Server step 1 — choose the source type (handoff 3b). An intro lockup, two option rows (Jellyfin
/// Server / Network Share), and the "More server types are on the way." footer. Selecting an option
/// pushes the matching sign-in step. The intro header (app icon + copy) shows on every platform — on
/// tvOS it's the screen's only identity, since the native collapsed-sidebar pill just reads "Settings".
struct AddServerChooseView: View {
    var onChooseJellyfin: () -> Void
    var onChooseSMB: () -> Void

    var body: some View {
        SettingsScaffold(showsBrand: false) {
            FormIntroHeader(title: "Add a Server", subtitle: "Choose how Parallax connects to your media.")
                .padding(.bottom, Space.s8)
            ServerTypeChoiceGroup(onChooseJellyfin: onChooseJellyfin, onChooseSMB: onChooseSMB)
        }
        .navigationTitle("Add Server")
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// The two source-type option rows (Jellyfin Server / Network Share) plus the "more types" footer —
/// shared by the signed-in Add-Server choose step (`AddServerChooseView`) and the logged-out first-run
/// Connect flow (`ConnectSourceView`), which are the same choice in two entry points. One source of truth
/// for the copy + icons so the two surfaces can't drift.
struct ServerTypeChoiceGroup: View {
    var onChooseJellyfin: () -> Void
    var onChooseSMB: () -> Void

    var body: some View {
        SettingsGroup(footer: "More server types are on the way.") {
            SettingsListRow(
                systemImage: "server.rack",
                iconSize: 22,
                title: "Jellyfin Server",
                subtitle: "Sign in to your media server",
                accessory: .chevron,
                action: onChooseJellyfin
            )
            SettingsListRow(
                systemImage: "externaldrive.badge.wifi",
                iconSize: 22,
                title: "Network Share",
                subtitle: "Connect over SMB to a shared folder",
                accessory: .chevron,
                action: onChooseSMB
            )
        }
    }
}

#if DEBUG
private struct AddServerChoosePreview: View {
    var body: some View {
        NavigationStack {
            AddServerChooseView(onChooseJellyfin: {}, onChooseSMB: {})
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
    }
}

#if os(tvOS)
#Preview("Add Server · choose", traits: .fixedLayout(width: 1920, height: 1080)) { AddServerChoosePreview() }
#else
#Preview("Add Server · choose", traits: .fixedLayout(width: 540, height: 760)) { AddServerChoosePreview() }
#endif
#endif
