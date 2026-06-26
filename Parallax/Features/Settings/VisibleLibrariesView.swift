import SwiftUI
import ParallaxCore
import ParallaxJellyfin

/// "Visible Libraries" picker (handoff 3h, the `4 of 6` row's destination). Lists a Jellyfin server's
/// libraries with a checkmark on each visible one; tapping toggles it. The de-selected set persists per
/// server (`ServerStore.setHiddenCollectionIDs`) and bumps the router's library revision, so the merged
/// library at every nav root (iPad sidebar, tvOS column, iPhone list) drops the hidden libraries live.
struct VisibleLibrariesView: View {
    let session: Session

    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router

    @State private var collections: [MediaCollection] = []
    @State private var hidden: Set<String> = []
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        SettingsScaffold(showsBrand: false) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else if let loadError {
                SettingsRetryError(message: loadError) { Task { await load() } }
            } else if collections.isEmpty {
                SettingsSectionFooter("This server has no libraries.")
            } else {
                SettingsGroup(footer: "Hidden libraries won’t appear in your library list.") {
                    ForEach(collections) { collection in
                        let visible = !hidden.contains(collection.id.rawValue)
                        Button { toggle(collection) } label: {
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
        }
        .navigationTitle("Visible Libraries")
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        hidden = await deps.serverStore.hiddenCollectionIDs(for: session.id)
        do {
            collections = try await deps.jellyfinLibraryRepoFactory(session).collections()
        } catch {
            loadError = "Couldn’t load this server’s libraries."
        }
        isLoading = false
    }

    private func toggle(_ collection: MediaCollection) {
        let id = collection.id.rawValue
        let wasHidden = hidden.contains(id)
        if wasHidden { hidden.remove(id) } else { hidden.insert(id) }
        let snapshot = hidden
        Task {
            do {
                try await deps.serverStore.setHiddenCollectionIDs(snapshot, for: session.id)
                // Rebuild the merged library wherever it's shown, so the change is immediate.
                router.bumpLibraryRevision()
            } catch {
                // Persist failed — revert the optimistic toggle so the checkmark matches what's stored,
                // and DON'T bump the revision (the roots would re-read the unchanged set and diverge from
                // this screen). The reverted checkmark is the feedback that the change didn't take.
                if wasHidden { hidden.insert(id) } else { hidden.remove(id) }
            }
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
    .background(Color.background)
}
#endif
