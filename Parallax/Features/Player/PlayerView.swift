import SwiftUI
import ParallaxCore
import ParallaxJellyfin
import ParallaxPlayback

struct PlayerView: View {
    private enum Source { case resolved(ItemDetail); case unresolved(ItemID) }
    private let source: Source
    let session: Session

    /// Play an already-loaded detail (e.g. the movie-detail Play button).
    init(item: ItemDetail, session: Session) {
        self.source = .resolved(item)
        self.session = session
    }
    /// Play by id — fetches the detail in the loading cover (direct episode play).
    init(itemID: ItemID, session: Session) {
        self.source = .unresolved(itemID)
        self.session = session
    }

    @Environment(AppDependencies.self) private var deps
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: PlayerViewModel?
    /// Aspect-fill (fill the screen, cropping) vs fit. Toggled by the player's
    /// expand chip; honored by the AVKit host's `videoGravity`.
    @State private var fillMode = false
    /// Chrome visibility, owned here so the status bar can hide with the controls.
    @State private var chromeVisible = true
    #if DEBUG
    @State private var showDebugHUD = false
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let vm = viewModel {
                switch vm.phase {
                case .idle, .loading:
                    videoHost(vm)
                case .playing:
                    videoHost(vm)
                    SubtitleOverlayView(vm: vm)
                    PlayerControlsView(vm: vm, controlsVisible: $chromeVisible, isFilled: fillMode, onToggleFill: { fillMode.toggle() }) { dismiss() }
                case .failed(let error):
                    errorOverlay(error, vm: vm)
                }
            }
        }
        // Loading visual: the video surface itself becomes the loader. The picture
        // calms to a dark field and a liquid-glass orb takes center — NOT a frosted
        // blocking pill. On a transcode track switch the engine is paused + reused, so
        // the last frame stays under the calm scrim until the new stream plays; on a
        // first play the field is the black floor. Fades out when playback resumes.
        .overlay {
            if showsReloadCover {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    if let vm = viewModel {
                        LoaderOrb(label: vm.loaderTitle, sublabel: vm.loaderSubtitle)
                    } else {
                        LoaderOrb()
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showsReloadCover)
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if showDebugHUD, let vm = viewModel {
                DebugInfoOverlay(vm: vm) { showDebugHUD = false }
                    .padding(.top, 70)
                    .padding(.leading, 16)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if viewModel != nil {
                Button("Toggle debug overlay", systemImage: "info.circle") {
                    showDebugHUD.toggle()
                }
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(.white.opacity(0.55))
                .padding(12)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showDebugHUD)
        #endif
        // No blanket .ignoresSafeArea() here: the black floor, video host, and reload
        // cover each opt into full-bleed individually (see above), while the chrome
        // (top bar, scrubber) and status bar respect the safe area. The status bar
        // hides in lockstep with the chrome.
        .statusBarHidden(!chromeVisible)
        .persistentSystemOverlays(chromeVisible ? .automatic : .hidden)
        .animation(.easeInOut(duration: 0.2), value: chromeVisible)
        // The controls (which restore chromeVisible) only exist in .playing. If the
        // stream fails after the chrome auto-hid, force it back so the status bar and
        // home indicator return over the error overlay — and so a successful retry
        // re-mounts the controls already visible.
        .onChange(of: isPlaybackActive) { _, active in
            if !active { chromeVisible = true }
        }
        .task {
            if viewModel == nil {
                let info = await deps.playbackInfoFactory(session)
                let repo = await deps.libraryRepoFactory(session)
                let engineFactory = deps.playbackEngineFactory
                let vm = PlayerViewModel(
                    deviceProfileBuilder: deps.deviceProfileBuilder,
                    playbackInfo: info,
                    resolve: { id, caps, start, audioIndex, subtitleIndex in
                        try await info.resolve(
                            item: id,
                            capabilities: caps,
                            startTime: start,
                            audioStreamIndex: audioIndex,
                            subtitleStreamIndex: subtitleIndex
                        )
                    },
                    engineFactory: { id in engineFactory(id) },
                    audioSession: deps.audioSession,
                    fetchDetail: { try await repo.detail(for: $0) }
                )
                viewModel = vm
                switch source {
                case .resolved(let item): await vm.start(item: item)
                case .unresolved(let id): await vm.start(itemID: id)
                }
            }
        }
        .onDisappear {
            let vm = viewModel
            Task { await vm?.stop() }
        }
    }

    /// True only while actively playing — gates the chrome-visibility reset above.
    private var isPlaybackActive: Bool {
        if case .playing = viewModel?.phase { return true }
        return false
    }

    /// Whether to show the frosted reload cover: before the VM exists and while it's
    /// idle/loading (initial load and a track-switch re-buffer). Hidden once playing
    /// (the video shows) or failed (the error overlay shows).
    private var showsReloadCover: Bool {
        guard let vm = viewModel else { return true }
        switch vm.phase {
        case .idle, .loading: return true
        case .playing, .failed: return false
        }
    }

    /// The engine-specific video surface. Shown for every phase except `.failed`.
    @ViewBuilder
    private func videoHost(_ vm: PlayerViewModel) -> some View {
        if let engine = vm.engine {
            switch engine.id {
            case .avKit:
                AVKitVideoLayerHost(engine: engine, fillMode: fillMode, onPiPReady: { start, stop in
                    vm.startPiPAction = start
                    vm.stopPiPAction = stop
                })
                .ignoresSafeArea()
            case .vlcKit:
                VLCVideoHost(engine: engine, onPiPReady: { start, stop in
                    vm.startPiPAction = start
                    vm.stopPiPAction = stop
                })
                .ignoresSafeArea()
            }
        }
    }

    /// Failure state. White-on-dark over the black player surface (so it ignores the
    /// app's light/dark tint — the old `.borderedProminent` Retry rendered white-on-
    /// white under the monochrome global tint). Solid-white "Try Again", glass "Close".
    @ViewBuilder
    private func errorOverlay(_ error: AppError, vm: PlayerViewModel) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .glassEffect(.regular, in: Circle())
            Text("Playback failed")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
            Text(error.userMessage)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button { Task { await vm.retry() } } label: {
                    Text("Try Again")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 24)
                        .frame(height: 46)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                Button { dismiss() } label: {
                    Text("Close")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .frame(height: 46)
                        .glassEffect(.regular, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: 460)
    }
}
