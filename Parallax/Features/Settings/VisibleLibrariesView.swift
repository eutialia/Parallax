import SwiftUI
import ParallaxCore
import ParallaxJellyfin
import ParallaxFeatures

/// "Visible Libraries" picker (handoff 3h, the `4 of 6` row's destination). Lists a Jellyfin server's
/// libraries with a checkmark on each visible one; tapping toggles it. The de-selected set persists per
/// server (`ServerStore.setHiddenCollectionIDs`) and bumps the router's library revision, so the merged
/// library at every nav root (iPad sidebar, tvOS column, iPhone list) drops the hidden libraries live.
struct VisibleLibrariesView: View {
    let session: Session

    @State private var model: VisibleLibrariesModel

    init(session: Session, app: AppModel) {
        self.session = session
        _model = State(initialValue: VisibleLibrariesModel(session: session, app: app))
    }

    var body: some View {
        SettingsScaffold(showsBrand: false) {
            if !model.isLoading {
                if let loadError = model.loadError {
                    SettingsRetryError(message: loadError) { Task { await model.load() } }
                } else if model.collections.isEmpty {
                    SettingsSectionFooter("This server has no libraries.")
                        .tvFocusableSurface()
                } else {
                    SettingsGroup(footer: "Hidden libraries won’t appear in your library list.") {
                        ForEach(model.collections) { collection in
                            let visible = !model.hidden.contains(collection.id.rawValue)
                            Button { Task { await model.toggle(collection) } } label: {
                                SettingsRowLabel(
                                    systemImage: collection.collectionType.symbolName,
                                    iconSize: 20,
                                    title: collection.name,
                                    accessory: visible ? .checkmark : .none
                                )
                            }
                            .tvListRowButton()
                            .accessibilityValue(visible ? "Visible" : "Hidden")
                        }
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 140)
                    // A pushed tvOS screen with no focusable content traps the remote (Menu
                    // suspends the app instead of popping) — the loading and empty states here
                    // are exactly that, so each keeps a focus target. The error branch has its
                    // Retry button; the loaded branch has the library rows.
                    .tvFocusableSurface()
            }
        }
        .navigationTitle("Visible Libraries")
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await model.load()
        }
    }
}

#if DEBUG
#Preview("Visible Libraries", traits: .fixedLayout(width: 540, height: 560)) {
    ScrollView {
        SettingsGroup(footer: "Hidden libraries won’t appear in your library list.") {
            Button {} label: { SettingsRowLabel(systemImage: "film", iconSize: 20, title: "Movies", accessory: .checkmark) }.buttonStyle(.plain)
            Button {} label: { SettingsRowLabel(systemImage: "tv", iconSize: 20, title: "TV Shows", accessory: .checkmark) }.buttonStyle(.plain)
            Button {} label: { SettingsRowLabel(systemImage: "music.note", iconSize: 20, title: "Music", accessory: .none) }.buttonStyle(.plain)
            Button {} label: { SettingsRowLabel(systemImage: "books.vertical", iconSize: 20, title: "Audiobooks", accessory: .checkmark) }.buttonStyle(.plain)
            Button {} label: { SettingsRowLabel(systemImage: "photo", iconSize: 20, title: "Home Videos", accessory: .none) }.buttonStyle(.plain)
        }
        .padding(Space.s18)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .screenFloor()
}
#endif
