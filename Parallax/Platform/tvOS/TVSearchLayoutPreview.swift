#if os(tvOS) && DEBUG
import SwiftUI

// Diagnostic previews for the tvOS search-tab layout: does the collapsed sidebar pill
// overlap the system search screen? Two arrangements of the SAME tab structure:
//
//   A. `.searchable` INSIDE the search tab's NavigationStack (the shape that shipped
//      first) — device screenshot showed the pill floating over the field's prompt.
//   B. `.searchable` on the TABVIEW — the shape `TabRole.search`'s docs describe
//      ("Searchable tab views will prefer to have the first tab with this role
//      implement search"), letting the tab host coordinate search with its own chrome.
//
// Self-contained (no app dependencies) so the difference is attributable to the
// searchable attachment point alone.
private enum DemoTab: Hashable { case home, search }

private struct DemoResults: View {
    var body: some View {
        Text("Results region")
            .font(.title3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SearchableInsideTab: View {
    @State private var selection = DemoTab.search
    @State private var query = ""

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: DemoTab.home) { Color.clear }
            Tab(value: DemoTab.search, role: .search) {
                NavigationStack {
                    DemoResults()
                        .searchable(text: $query, prompt: "Search your library")
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

private struct SearchableOnTabView: View {
    @State private var selection = DemoTab.search
    @State private var query = ""

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: DemoTab.home) { Color.clear }
            Tab(value: DemoTab.search, role: .search) {
                NavigationStack {
                    DemoResults()
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .searchable(text: $query, prompt: "Search your library")
    }
}

private struct SearchableInsetBelowPill: View {
    @State private var selection = DemoTab.search
    @State private var query = ""

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: DemoTab.home) { Color.clear }
            Tab(value: DemoTab.search, role: .search) {
                NavigationStack {
                    DemoResults()
                        .searchable(text: $query, prompt: "Search your library")
                        // Clear the floating sidebar chrome. Plain padding (not
                        // safeAreaPadding — the search chrome ignores safe area,
                        // render-proven) INSIDE the stack, so pushed screens
                        // (full-bleed detail heroes) don't inherit the dent.
                        .padding(.top, AppLayout.tvSearchTopClearance)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

private struct SearchableChromeHidden: View {
    @State private var selection = DemoTab.search
    @State private var query = ""

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: DemoTab.home) { Color.clear }
            Tab(value: DemoTab.search, role: .search) {
                NavigationStack {
                    DemoResults()
                        .searchable(text: $query, prompt: "Search your library")
                }
                .toolbar(.hidden, for: .tabBar)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

#Preview("A · searchable inside tab") {
    SearchableInsideTab()
}

#Preview("B · searchable on TabView") {
    SearchableOnTabView()
}

#Preview("C · inset below pill") {
    SearchableInsetBelowPill()
}

#Preview("D · tab chrome hidden") {
    SearchableChromeHidden()
}
#endif
