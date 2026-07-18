#if !os(tvOS) && DEBUG
import SwiftUI

// Diagnostic preview for the iPad scope-row band: reproduces the search tab's exact
// chrome stack (sidebarAdaptable TabView → search-role tab → NavigationStack → drawer
// searchable + scopes) over the daylight floor, with search presented so the scope row
// renders. Render on an iPad destination to inspect how the scope strip blends with
// the floor; `previewVariant` toggles the candidate treatments for A/B renders.
private enum DemoTab: Hashable { case home, search }

private struct ScopeBandDemo: View {
    /// 0 = shipping treatment, 1 = hard edge (the bug's look), 2 = edge effect hidden.
    var variant = 0
    /// false = drop `.searchScopes` (the system capsule ships its own glass drop shadow)
    /// and render a flat in-content segmented Picker below the field instead.
    var useSystemScopes = true

    @State private var selection = DemoTab.search
    // Non-empty so the scope row (the band's home) renders in a static preview.
    @State private var query = "blade"
    @State private var scope = 0

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: DemoTab.home) { Color.clear }
            Tab(value: DemoTab.search, role: .search) {
                NavigationStack {
                    searchContent
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .background(Color.background.ignoresSafeArea())
    }

    private var searchContent: some View {
        VStack(spacing: 0) {
            if !useSystemScopes, !query.isEmpty {
                Picker("Search scope", selection: $scope) {
                    Text("All").tag(0)
                    Text("Movies").tag(1)
                    Text("Shows").tag(2)
                    Text("Episodes").tag(3)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Space.s16)
                .padding(.vertical, Space.s8)
            }
            ScrollView {
                LazyVStack(spacing: Space.s12) {
                    ForEach(0..<30, id: \.self) { i in
                        Text("Result row \(i)")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Space.s12)
                            .background(Color.fill, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal, Space.s16)
            }
        }
        .searchable(
            text: $query,
            isPresented: .constant(true),
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search your library"
        )
        .modifier(SystemScopes(enabled: useSystemScopes, scope: $scope))
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .modifier(EdgeTreatment(variant: variant))
        .screenFloor()
    }
}

private struct SystemScopes: ViewModifier {
    var enabled: Bool
    @Binding var scope: Int

    func body(content: Content) -> some View {
        if enabled {
            content.searchScopes($scope) {
                Text("All").tag(0)
                Text("Movies").tag(1)
                Text("Shows").tag(2)
                Text("Episodes").tag(3)
            }
        } else {
            content
        }
    }
}

private struct EdgeTreatment: ViewModifier {
    var variant: Int

    func body(content: Content) -> some View {
        switch variant {
        case 1: content.scrollEdgeEffectStyle(.hard, for: .top)
        case 2: content.scrollEdgeEffectHidden(for: .top)
        default: content.scrollEdgeEffectStyle(.soft, for: .top)
        }
    }
}

#Preview("scope band · soft (shipping)") {
    ScopeBandDemo(variant: 0)
}

#Preview("scope band · hard") {
    ScopeBandDemo(variant: 1)
}

#Preview("scope band · hidden") {
    ScopeBandDemo(variant: 2)
}

#Preview("scope band · in-content picker") {
    ScopeBandDemo(useSystemScopes: false)
}
#endif
