import SwiftUI
import ParallaxJellyfin
import ParallaxCore

/// The iPhone Library tab: every configured source's libraries as 16:9 banner cards, grouped
/// into one titled section per server in the order the user added them — the card-list analogue
/// of the iPad/tvOS sidebar's per-server `TabSection`s. Libraries are never merged across
/// servers, so two servers that both expose "Movies" show two cards under two headers.
///
/// Pure presentation: `LibraryHostView` owns the resolution (one `MergedLibrary.resolve` across
/// every source) and the load/failure states. This view used to own a Jellyfin-only
/// `LibraryListViewModel` that re-fetched `collections()` and re-applied the hidden-library
/// filter itself — a second copy of what `MergedLibrary` already does, and structurally
/// single-server. It's gone; there is one resolver now.
struct LibraryListView: View {
    /// One group per source, in add order. Already filtered (hidden + unsupported types).
    let groups: [LibraryGroup]
    /// Whether to offer the cross-server Favorites card. False in an SMB-only config (favorites are
    /// a Jellyfin concept). `FavoritesView` resolves its own servers, so no session is threaded
    /// through — a single one would have been the wrong shape anyway now that the wall spans them all.
    var showsFavorites: Bool = false
    /// Servers whose libraries couldn't be listed this pass. Named above the grid rather than
    /// dropped silently: the full-screen failure state only covers "every source failed", so
    /// without this a partial outage is indistinguishable from having fewer libraries.
    var unreachableServers: [String] = []

    @Environment(\.appIdiom) private var idiom

    var body: some View {
        ScrollView {
            if !unreachableServers.isEmpty {
                UnreachableServersNotice(names: unreachableServers)
                    .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
                    .padding(.bottom, Space.s12)
            }
            // Jellyfin renders library art at 16:9 with the name baked in, so these are wide
            // banners: three-up on tvOS, two-up on iPad, one-up on iPhone.
            let cols = AppLayout.libraryListColumns(idiom: idiom)
            let gap = AppLayout.libraryListSpacing(idiom: idiom)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: gap), count: cols),
                spacing: gap
            ) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.entries) { LibraryEntryCell(entry: $0) }
                    } header: {
                        // A single source needs no header — there's nothing to disambiguate it
                        // from, and a lone server name above the only section is noise. This is
                        // also what replaced the old `.navigationSubtitle(session.serverName)`,
                        // which named ONE server above a list that already mixed Jellyfin and SMB.
                        if groups.needsPerSourceTitles {
                            LibrarySectionHeader(title: group.title)
                        }
                    }
                }
                // The virtual cross-server Favorites grid, riding the same banner grid as the
                // server libraries — last, and outside every server's section, because favorites
                // span servers (the iPad/tvOS sidebar lists it as a top-level tab for the same
                // reason).
                if showsFavorites {
                    NavigationLink(value: FavoritesRoute()) { FavoritesCard() }
                        // Same `LibraryBannerCard` chrome as the banners above — the tile idiom
                        // applies here too.
                        .pressableTileButton()
                }
            }
            .padding(AppLayout.contentHMargin(idiom: idiom))
        }
        // Don't clip a focused card's lift at the scroll bounds.
        .tvScrollClipDisabled()
        // One drill-down dispatch for every source (Jellyfin grid / SMB folder browser).
        .smbLibraryDestination()
        .navigationDestination(for: FavoritesRoute.self) { _ in
            FavoritesView()
                .tvHidesTabSidebar()
        }
    }
}

/// Names the servers missing from the list this pass. Deliberately a quiet inline notice, not an
/// alert or a full-screen state: the libraries that DID load are right below it and stay usable, so
/// this is information, not an interruption. Recovery is automatic (`.recoversFromOffline` on the
/// host), which is why there's no retry button to press.
private struct UnreachableServersNotice: View {
    let names: [String]

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.subheadline)
            .foregroundStyle(Color.secondaryLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }

    private var message: String {
        // Named while the list is short enough to read; past that a count carries the same meaning
        // without turning the notice into a paragraph.
        if names.count <= 2 {
            return "Couldn't reach \(names.joined(separator: " and ")). Its libraries are missing."
        }
        return "Couldn't reach \(names.count) servers. Their libraries are missing."
    }
}

/// A server's name above its block of library cards. Deliberately quiet — it's a grouping label,
/// not a title; the screen's title is "Library".
private struct LibrarySectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .scaledFont(15, relativeTo: .subheadline, weight: .semibold)
            .foregroundStyle(Color.secondaryLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Space.s12)
            .padding(.bottom, Space.s3)
            .accessibilityAddTraits(.isHeader)
    }
}

#if DEBUG
/// Two servers' libraries in the card list — the shape that only exists once a second source is
/// configured. The point is to check that the section headers read as *grouping labels* under the
/// "Library" title rather than competing with it, and that a Jellyfin banner and an SMB card sit
/// legibly in the same column. Jellyfin banner art needs a live server, so both groups here are
/// SMB-sourced (self-painted cards) — the layout question is the headers and rhythm, not the art.
private struct LibraryListSectionsPreview: View {
    var body: some View {
        NavigationStack {
            LibraryListSectionsGrid()
                .navigationTitle("Library")
        }
        .screenFloor()
    }
}

/// The two-server list itself, without a nav stack or floor — shared by the preview above and the
/// skeleton parity check below, which supplies its own shell.
private struct LibraryListSectionsGrid: View {
    var body: some View {
        LibraryListView(
            groups: [
                Self.group(host: "attic.local", shares: ["Films", "Series"]),
                Self.group(host: "basement.local", shares: ["Films", "Archive"]),
            ]
        )
    }

    private static func group(host: String, shares: [String]) -> LibraryGroup {
        let ref = SMBServerRef(
            id: ServerID(rawValue: "smb-\(host)"),
            data: SMBServerData(host: host, username: "guest", domain: "", shares: shares)
        )
        return LibraryGroup(
            source: .smb(ref),
            entries: shares.map { share in
                LibraryEntry(
                    source: .smb(ref),
                    collection: MediaCollection(
                        id: CollectionID(rawValue: share),
                        name: share,
                        collectionType: .movies,
                        primaryTag: nil
                    )
                )
            }
        )
    }
}

#Preview("Library list — two servers", traits: .fixedLayout(width: 393, height: 852)) {
    LibraryListSectionsPreview()
        .environment(\.appIdiom, .compact)
}

/// Makes `LibraryListLoadingSkeleton`'s single-section contract VISIBLE: placeholder left, the
/// two-server list right. The card grid's columns, gap and inset match; the placeholder deliberately
/// reserves no per-server header, because when it is on screen the group count is still a network
/// answer away (the full reasoning lives on `LibraryListLoadingSkeleton`). So the right half's first
/// card sits one `LibrarySectionHeader` lower — that delta is the documented cost of NOT guessing,
/// and this preview is where it stays honest. A single-source config, which is the common one, has
/// no header on either side.
///
/// `python3 scripts/render-ruler.py --pt-width 786 --scan-col 0.25,0.75`.
///
/// Both halves are exactly ONE scroll deep: `LibraryListView.body` IS a `ScrollView`, and the
/// placeholder's shell (`LibraryListLoadingPlaceholder`) is one too. Wrapping the loaded half in a
/// second `ScrollView` measured a nesting the app never draws.
#Preview("Library list skeleton ↔ two servers", traits: .fixedLayout(width: 786, height: 700)) {
    NavigationStack {
        SkeletonParity(idiom: .compact, columnWidth: 393) {
            LibraryListLoadingPlaceholder()
        } loaded: {
            LibraryListSectionsGrid()
        }
    }
}
#endif

/// One library banner in the card list, dispatched by source: a Jellyfin collection renders its
/// server banner art, an SMB share the neutral self-painted card. Both push the SAME
/// `LibraryEntry` navigation value, so `libraryEntryDestination(for:)` is the one place the
/// source branch lives (Jellyfin used to push a bare `MediaCollection` through a second
/// destination, which couldn't carry which server it came from).
struct LibraryEntryCell: View {
    let entry: LibraryEntry

    var body: some View {
        NavigationLink(value: entry) {
            switch entry.source {
            case .jellyfin(let session):
                LibraryCard(collection: entry.collection, session: session)
            case .smb:
                LibraryCard(smb: entry.collection)
            }
        }
        // Banner reads as a bounded artwork card (clip, shadow, chip, one-up on iPhone) not a
        // text list row — same tile idiom as the grid/shelf tiles; tvOS forwards to
        // `tvPosterButton()`.
        .pressableTileButton()
    }
}
