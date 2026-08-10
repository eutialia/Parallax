import SwiftUI
import ParallaxJellyfin
import ParallaxCore

struct JellyfinSearchView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @Environment(UserDataActions.self) private var userDataActions
    @State private var viewModel: JellyfinSearchViewModel?
    // Bind the search field to local state so keystrokes typed before the VM
    // finishes its async construction aren't dropped on the floor (the old
    // `viewModel?.query = $0` was a silent no-op while viewModel was nil).
    @State private var query = ""
    @State private var scope: SearchScope = .all
    @Environment(\.appIdiom) private var idiom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            // iOS/iPadOS scope row: OURS, in content — deliberately NOT `.searchScopes`.
            // The system scope capsule renders in the search presentation layer with its
            // own Liquid Glass drop shadow and no styling API — an unblended floating
            // slab on the flat floor (render-proven in SearchScopeBandPreview).
            //
            // Keyed on the VM's STATE, not `query.isEmpty`: the query flips on the
            // keystroke but the content swaps 350ms later (debounce), so a query-keyed
            // row moved in its own separate step — content pushed down first when typing,
            // row hiding first when clearing. State-keyed, the row enters exactly when
            // the placeholder gives way to the skeleton/results (and stays up through
            // the failure state, where switching scope re-runs the search) and leaves
            // exactly when the placeholder returns: one coordinated, symmetric motion.
            #if !os(tvOS)
            if scopesVisible {
                Picker("Search scope", selection: $scope) {
                    scopeOptions
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
                .padding(.top, Space.s8)
                .padding(.bottom, Space.s12)
                // Reduce Motion drops the slide for a plain fade (movement → cross-dissolve).
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            #endif

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // iOS only: coordinates the scope row's slide with the content swap it rides on.
        // tvOS draws its own scope row (`SearchScopeChips`) in-content now, inside the
        // persistent `TVSearchScopeSurface` (see `content` below) — not the system search
        // chrome — but that row doesn't slide in/out with a transition, so it has nothing
        // for this transaction to coordinate.
        #if !os(tvOS)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: scopesVisible)
        #endif
        // The SYSTEM search FIELD on every platform — no custom in-content field. tvOS renders
        // the HIG search screen (system keyboard on top, results beneath). iPhone/iPad use the
        // DRAWER placement: the wide bar stacked below the nav bar, shown ONLY on this tab —
        // the Apple-TV-app search layout the WWDC25-323 session also demonstrates (~13:24),
        // NOT the default iPadOS 26 trailing-corner field. Being chrome-hosted keeps the field
        // out of the keyboard-avoidance path that shoved the old in-content bar off-screen.
        //
        // TRIED AND REVERTED (2026-08-10, owner-rejected on device): `.searchable` hoisted onto
        // the TabView paired with the tab's `role: .search` — the session's OTHER search shape.
        // That floats a search affordance across every tab's chrome; this app wants the field to
        // exist only on the search page, full width. Don't re-hoist.
        //
        // The scope selector is OURS on BOTH platforms — deliberately no `.searchScopes` in any
        // production path. (The one exception is `SearchScopeBandPreview`, a `#if !os(tvOS) && DEBUG`
        // A/B harness that renders the system control on purpose, to keep the comparison this
        // decision rests on reproducible.)
        // tvOS used to use it and the bar rendered in the search PRESENTATION layer: chrome outside
        // this view tree, so it could never scroll away with the results (it read as "always
        // centered" on device) and the focus engine treated it as system chrome. tvOS now draws
        // `SearchScopeChips` inside the scrolling content; iOS keeps the segmented Picker above it.
        #if os(tvOS)
        .searchable(text: $query, prompt: Self.searchPrompt)
        #else
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Self.searchPrompt
        )
        // Keep the stacked drawer field IN PLACE while editing. Without this, activating
        // search lets the toolbar "adapt to the search presentation" — on iPadOS 26 the
        // wide drawer bar collapses into the top-trailing corner the moment it's tapped.
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        #endif
        // Media titles are proper nouns and non-dictionary words ("Nosferatu", "Ex
        // Machina") — the old custom field disabled these deliberately; carry that
        // through to the system field (both propagate via the environment).
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        // Match the old custom-bar behavior: the first scroll motion drops the keyboard
        // (the system default keeps it up for plain ScrollViews). No-op on tvOS.
        .scrollDismissesKeyboard(.immediately)
        #if os(tvOS)
        // Drop the system search screen below the floating sidebar pill — see
        // `AppLayout.tvSearchTopClearance`. Applied INSIDE the stack (on the searchable
        // screen, not the NavigationStack) so pushed detail heroes stay full-bleed.
        .padding(.top, AppLayout.tvSearchTopClearance)
        #else
        // Keep a (title-less) nav bar so the .zoom push into item detail still has a
        // shared bar to hand its back button to — never `.toolbar(.hidden)` here.
        .navigationBarTitleDisplayMode(.inline)
        // Transparent bar, matching Home and the detail screens: the drawer + scope strip
        // otherwise paint the system bar material — an off-tone band that doesn't blend
        // with the daylight floor. Background only; the bar itself stays (zoom rule above).
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        // Soft top edge: the HIG-recommended style on iPadOS ("hard" is primarily macOS).
        // Over the flat floor it reads as no edge at all while still fading results that
        // scroll up under the drawer field.
        .scrollEdgeEffectStyle(.soft, for: .top)
        #endif
        .onChange(of: query) { _, newValue in
            viewModel?.query = newValue
        }
        .onChange(of: scope) { _, newValue in viewModel?.scope = newValue }
        // A scope outlives its search session otherwise: search "Batman" scoped to
        // Episodes, clear, search "Dune" — with the scope control hidden at idle, the
        // stale Episodes scope would silently narrow the new search. Ending a session
        // resets to All, so every fresh search starts unscoped, control visible or not.
        .onChange(of: scopesVisible) { _, visible in
            if !visible { scope = .all }
        }
        .screenFloor()
        .itemDetailNavigation()
        // Search's status states (idle prompt, no results, failed) always render under the
        // system search keyboard — focus always has a real home here, so the tvOS
        // focus-target fallback must not add an invisible surface that competes with it
        // (see `statusStateProvidesTVFocusTarget`).
        .environment(\.statusStateProvidesTVFocusTarget, false)
        // Keyed on the reload token, not `activeServerID`: search aggregates EVERY signed-in
        // server, so adding or removing one must rebuild the provider list — and adding a second
        // server never moves the active id (see AppRouter.libraryReloadToken).
        .task(id: router.libraryReloadToken) {
            let providers = await JellyfinSearchProvider.all(
                for: await deps.serverStore.sessions,
                repoFactory: deps.jellyfinLibraryRepoFactory
            )
            guard !providers.isEmpty else { return }
            // Rebuild when the SET of servers changed, not just when there's no model yet: a
            // model's providers are fixed at init, so signing into a second server left the
            // existing single-server model in place and Search kept querying one server until the
            // next launch — the exact bug keying this task on the reload token exists to fix.
            if viewModel?.matches(providers) != true {
                let vm = JellyfinSearchViewModel(providers: providers, userDataActions: userDataActions)
                vm.start()
                // Seed any text/scope set during construction before wiring up — the
                // field is live while the VM builds, so both can change in that window.
                if !query.isEmpty { vm.query = query }
                if scope != .all { vm.scope = scope }
                viewModel = vm
            }
        }
        // Auto-recover a failed search when the network returns (or the app foregrounds online) by
        // re-running the current query. Gated on `isStalled` so a results page is never re-queried.
        .recoversFromOffline(isStalled: viewModel?.isStalled ?? false) { await viewModel?.retry() }
    }

    /// The screen's content, in ONE of two shells.
    ///
    /// tvOS mounts a SINGLE `TVSearchScopeSurface` for every state — including the pre-view-model
    /// placeholder — so the scope-chip row lives at one fixed position in the view tree while the
    /// body under it swaps. That is load-bearing, not tidiness: the row used to be rebuilt inside
    /// each branch, so narrowing the scope to zero results tore the FOCUSED chip out of the tree
    /// and the focus engine handed focus back to the system keyboard.
    ///
    /// iPhone/iPad keep the shape they always had: a scroll shell for the states that scroll, and
    /// the status states BARE — `StatusStateView` sizes itself to the whole viewport, so putting it
    /// inside a scroll view alongside other content is exactly what it's built not to do.
    @ViewBuilder
    private var content: some View {
        if idiom == .tv {
            TVSearchScopeSurface(
                scope: scope,
                showsScopes: scopesVisible,
                isShowingSkeleton: isShowingSkeleton,
                onSelectScope: { scope = $0 }
            ) {
                stateBody
            }
            .overlay(alignment: .top) { refiningIndicator }
        } else if scrollsStateBody {
            ScrollView {
                stateBody
            }
            // Only the skeleton locks scrolling; a loaded grid scrolls normally.
            .scrollDisabled(isShowingSkeleton)
            .contentMargins(.horizontal, AppLayout.contentHMargin(idiom: idiom), for: .scrollContent)
            .contentMargins(.vertical, AppLayout.searchContentVMargin(idiom: idiom), for: .scrollContent)
            .overlay(alignment: .top) { refiningIndicator }
        } else {
            stateBody
        }
    }

    /// What the current state draws, with no shell around it — shared by both branches above so the
    /// state vocabulary exists once.
    @ViewBuilder
    private var stateBody: some View {
        if let vm = viewModel {
            switch vm.state {
            case .idle:
                // No scope row here: `hasActiveSearch` is false at idle, so iOS hides its Picker too.
                StatusStateView(
                    title: "Find something to watch",
                    systemImage: "magnifyingglass",
                    message: "Movies, shows, and episodes from your library."
                )
            case .loading:
                PosterGridLoadingSkeleton(columns: posterCols, rows: 2)
            case .loaded(let results):
                if results.isEmpty {
                    StatusStateView.searchNoResults
                } else {
                    // `.equatable()` so a per-keystroke `query` change can't re-render the tiles
                    // (see JellyfinSearchResultsView). The refine overlay stays out in the shell,
                    // in the reactive parent.
                    JellyfinSearchResultsView(results: results).equatable()
                }
            case .failed(let message):
                StatusStateView.failure("Couldn't search your library", message: message)
            }
        } else {
            // The view model is still building — same skeleton, and `scopesVisible` is false, so
            // tvOS shows no chips yet either.
            PosterGridLoadingSkeleton(columns: posterCols, rows: 2)
        }
    }

    /// Floating indicator while refining an on-screen result set — an overlay on the scroll shell
    /// (not an inline row) so the results don't shift down/up on every debounced keystroke. Only
    /// over a NON-EMPTY loaded grid: the loading skeleton is already its own progress signal.
    @ViewBuilder
    private var refiningIndicator: some View {
        if let vm = viewModel, vm.isSearching, case .loaded(let results) = vm.state, !results.isEmpty {
            SearchRefiningSkeleton()
                // Passive status capsule, not a control — on tvOS it overlays the chip row
                // region, and without this it would swallow focus/select from underneath.
                .allowsHitTesting(false)
        }
    }

    /// The states that render scrolling content on iPhone/iPad: the skeleton and a non-empty grid.
    /// The status states own the whole viewport and stay out of a scroll (see `content`).
    private var scrollsStateBody: Bool {
        guard let vm = viewModel else { return true }
        switch vm.state {
        case .loading: return true
        case .loaded(let results): return !results.isEmpty
        case .idle, .failed: return false
        }
    }

    /// True while the skeleton is what's on screen — the pre-view-model placeholder and `.loading`
    /// render the same thing and both lock scrolling.
    private var isShowingSkeleton: Bool {
        guard let vm = viewModel else { return true }
        return vm.state == .loading
    }

    /// The scope row rides the VM's session flag so its show/hide is one motion with the
    /// content swap (see the comment at the row) — false while the VM is still building.
    private var scopesVisible: Bool {
        viewModel?.hasActiveSearch ?? false
    }

    #if !os(tvOS)
    /// The iOS Picker's rows, rendered from `SearchScopeOption.allOptions` — the ONE scope
    /// vocabulary, shared with the tvOS chip row so the two platforms' lists can't drift. The
    /// vocabulary is a value list rather than this `@ViewBuilder` because the chips need
    /// focusable Buttons, not `Text().tag()` rows.
    @ViewBuilder private var scopeOptions: some View {
        ForEach(SearchScopeOption.allOptions) { option in
            Text(option.title).tag(option.scope)
        }
    }
    #endif

    private static let searchPrompt = "Search your library"

    private var posterCols: Int { AppLayout.searchPosterColumns(idiom: idiom) }
}

