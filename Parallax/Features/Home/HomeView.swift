import SwiftUI
import ParallaxJellyfin

struct HomeView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackPresenter.self) private var playback
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var viewModel: HomeViewModel?
    @State private var session: Session?
    /// Hero CTA height scales with Dynamic Type (relative to its `.headline` label).
    @ScaledMetric(relativeTo: .headline) private var heroButtonHeight: CGFloat = 46

    var body: some View {
        ScrollView {
            content
        }
        .scrollClipDisabled(true)
        // Fill the detail width even while the loading state's content is small —
        // otherwise on a cold launch the ScrollView collapses to its content's ideal
        // width (~100pt for the loading spinner) until a later layout pass, showing a
        // narrow strip. Greedy frame pins it to the proposed width from the first pass.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Solid floor under the scroll content so the floating iPadOS 26
        // sidebar's translucent material blurs over the app background
        // instead of letting tile imagery bleed through.
        .background(Color.background)
        .ignoresSafeArea(edges: .top)
        .navigationTitle("Home")
        .toolbar(.hidden, for: .navigationBar)
        .itemZoomNavigation()
        .task {
            if session == nil {
                session = await deps.serverStore.active
            }
            if viewModel == nil, let session {
                let repo = await deps.libraryRepoFactory(session)
                viewModel = HomeViewModel(repo: repo)
                await viewModel?.load()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let vm = viewModel, let session {
            switch vm.state {
            case .idle, .loading:
                ProgressView().padding(Space.s40)
            case .loaded:
                LazyVStack(alignment: .leading, spacing: Space.s30) {
                    if let featured = vm.continueWatching.first ?? vm.nextUp.first {
                        heroSection(featured: featured, session: session)
                    }
                    if !vm.continueWatching.isEmpty {
                        MetadataRow(title: "Continue Watching", items: vm.continueWatching, tileWidth: 240) { item in
                            itemTile(item: item, session: session, showProgress: true)
                        }
                    }
                    if !vm.nextUp.isEmpty {
                        MetadataRow(title: "Next Up", items: vm.nextUp, tileWidth: 240) { item in
                            itemTile(item: item, session: session, showProgress: false)
                        }
                    }
                    if vm.continueWatching.isEmpty && vm.nextUp.isEmpty {
                        ContentUnavailableView("Nothing to resume", systemImage: "play.slash").padding(.top, Space.s60)
                    }
                }
                .padding(.bottom, Space.s30)
            case .failed(let message):
                ContentUnavailableView(
                    "Couldn't load Home",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
                .padding(.top, Space.s60)
            }
        } else {
            ProgressView().padding(Space.s40)
        }
    }

    @ViewBuilder
    private func landscapeTile(item: Item, session: Session, showProgress: Bool) -> some View {
        MediaTile(
            title: item.displayTitle,
            subtitle: tileSubtitle(item),
            imageRef: landscapeImage(item),
            imageKind: landscapeImageKind(item),
            session: session,
            progress: showProgress ? tileProgress(item) : nil,
            aspectRatio: JellyfinImage.landscape,
            maxImageWidth: 600
        )
    }

    // MARK: - Item rendering helpers
    @ViewBuilder
    private func itemTile(item: Item, session: Session, showProgress: Bool) -> some View {
        ItemNavigator(item: item, session: session) {
            landscapeTile(item: item, session: session, showProgress: showProgress)
        }
    }

    private func tileSubtitle(_ item: Item) -> String? {
        switch item {
        // Home rows show only the title for movies/series; episodes get a
        // compact SxxExx so the tile reads "name / S01E04" (smoke-test #7).
        case .movie, .series: return nil
        case .episode(let e): return e.episodeCode
        }
    }

    // For landscape Home rows we want 16:9 imagery for every type. Episodes'
    // .primary IS a 16:9 still; movies/series prefer .thumb then .backdrop
    // then fall back to the poster as last resort (still cropped to 16:9 fill).
    private func landscapeImage(_ item: Item) -> ImageRef? {
        switch item {
        case .movie(let m):
            return m.imageRef(.thumb) ?? m.imageRef(.backdrop(index: 0)) ?? m.imageRef(.primary)
        case .series(let s):
            return s.imageRef(.thumb) ?? s.imageRef(.backdrop(index: 0)) ?? s.imageRef(.primary)
        case .episode(let e):
            return e.imageRef(.primary)
        }
    }

    private func landscapeImageKind(_ item: Item) -> ImageKind {
        switch item {
        case .movie(let m):
            if m.imageRef(.thumb) != nil { return .thumb }
            if m.imageRef(.backdrop(index: 0)) != nil { return .backdrop(index: 0) }
            return .primary
        case .series(let s):
            if s.imageRef(.thumb) != nil { return .thumb }
            if s.imageRef(.backdrop(index: 0)) != nil { return .backdrop(index: 0) }
            return .primary
        case .episode: return .primary
        }
    }

    @ViewBuilder
    private func heroSection(featured: Item, session: Session) -> some View {
        HeroBackdrop(height: hSize == .regular ? 540 : 380) {
            // No `matchedTransitionSource` here: `featured` is always the first
            // tile of a visible Continue Watching / Next Up row, and that tile
            // already registers the zoom source. Two views with the same source
            // id in one namespace is undefined per Apple, so the hero defers to
            // the row tile (which sits directly below it) as the single source.
            JellyfinImage(
                ref: landscapeImage(featured),
                kind: landscapeImageKind(featured),
                session: session,
                maxWidth: 1600,
                aspectRatio: JellyfinImage.landscape,
                fillsProposedFrame: true
            )
        } foreground: {
            VStack(alignment: .leading, spacing: Space.s12) {
                Text("FEATURED")
                    .font(.caption.weight(.bold)).tracking(1.5)
                    .foregroundStyle(.white.opacity(0.7))
                Text(featured.displayTitle)
                    .scaledFont(hSize == .regular ? 52 : 32, relativeTo: .largeTitle, weight: .heavy)
                    .foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.7)
                if let meta = heroMeta(featured) {
                    Text(meta).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                }
                heroPlayButton(featured: featured, session: session)
                    .padding(.top, Space.s8)
            }
        }
    }

    private func heroMeta(_ item: Item) -> String? {
        switch item {
        case .movie(let m):
            var parts: [String] = []
            if let y = m.year { parts.append(String(y)) }
            if let r = m.runtime { parts.append("\(Int(r.components.seconds / 60)) min") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .series(let s): return s.year.map(String.init)
        case .episode(let e):
            if let season = e.parentIndexNumber, let idx = e.indexNumber { return "S\(season) · E\(idx)" }
            return nil
        }
    }

    // The hero CTA plays a movie/episode directly; a series can't be "played"
    // (PlayerViewModel rejects .series), so it navigates to the series screen.
    @ViewBuilder
    private func heroPlayButton(featured: Item, session: Session) -> some View {
        switch featured {
        case .series(let s):
            let nav = ItemNavigation.series(s.id, session)
            NavigationLink(value: nav) {
                heroButtonLabel("View", icon: "chevron.right")
            }
        case .movie, .episode:
            Button { playback.play(featured.id, in: session) } label: {
                heroButtonLabel("Play", icon: "play.fill")
            }
        }
    }

    private func heroButtonLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline).foregroundStyle(Color.buttonLabel)
            .padding(.horizontal, Space.s22).frame(height: heroButtonHeight)
            .background(Color.buttonFill, in: Capsule())
    }

    private func tileProgress(_ item: Item) -> Double? {
        let runtimeTicks: Int64?
        switch item {
        case .movie(let m): runtimeTicks = m.runtime.map { Int64($0.components.seconds) * 10_000_000 }
        case .series: runtimeTicks = nil
        case .episode(let e): runtimeTicks = e.runtime.map { Int64($0.components.seconds) * 10_000_000 }
        }
        return item.userData.playedFraction(runtimeTicks: runtimeTicks)
    }
}
