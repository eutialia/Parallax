/// One source's libraries, as one sidebar section / one titled block in the iPhone card list.
///
/// Libraries are deliberately NOT merged across servers: two servers that both call a library
/// "Movies" stay two libraries, in two groups. The group is the unit of *presentation* for that
/// separation — `MergedLibrary` emits one per configured source, in the order the user added
/// their servers, and every navigation root renders them as a titled, collapsible section
/// (`TabSection` on iPad/tvOS, a section header on iPhone).
///
/// Identity is the source, so a group survives its server's libraries changing underneath it
/// (a "Visible Libraries" edit rewrites `entries` without the section itself re-identifying and
/// animating out).
struct LibraryGroup: Identifiable, Hashable {
    let source: LibrarySource
    /// This source's libraries, in the order the source returned them (Jellyfin's own view order;
    /// the user's saved share order for SMB).
    let entries: [LibraryEntry]

    var id: MediaSourceID { source.sourceID }

    /// The section header: the Jellyfin server's name, or the SMB host.
    var title: String { source.displayName }
}

extension Array where Element == LibraryGroup {
    /// Every entry across every group, flattened in group order. The roots' stale-tab snapping and
    /// the SMB-only list want a flat list; the sidebar wants the groups. Both read the same
    /// resolution rather than resolving twice.
    var allEntries: [LibraryEntry] { flatMap(\.entries) }

    /// Whether the whole list should be titled per-source. With a single configured source the
    /// per-server header is noise — there's nothing to disambiguate it from — so the roots fall
    /// back to one plain "Libraries" section, exactly as before multi-server. Two or more sources
    /// title each section with its server name.
    var needsPerSourceTitles: Bool { count > 1 }

    /// This group's section header. Resolved here, as a plain `String`, because the call sites are
    /// `TabSection(_:)` — which has four overloads (`LocalizedStringKey` / `StringProtocol`, each
    /// × optional selection). Passing a ternary into that overload set is what pushed the roots'
    /// `TabView` bodies into "unable to type-check this expression in reasonable time"; a
    /// pre-resolved `String` collapses it to one candidate.
    func sectionTitle(for group: LibraryGroup) -> String {
        needsPerSourceTitles ? group.title : "Libraries"
    }
}
