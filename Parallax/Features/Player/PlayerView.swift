import SwiftUI
import CoreMedia
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
    /// Chrome visibility, owned here so the status bar can hide with the controls.
    /// On tvOS this mirrors `hudState == .fullHUD` (driven by `send`).
    @State private var chromeVisible = true
    #if os(tvOS)
    /// The tvOS HUD floor state machine (floor → swipeScrub → clickSeek → fullHUD),
    /// driven by `TVRemoteInputView` through `send(_:_:)`. See `PlayerHUDReducer`.
    @State private var hudState: PlayerHUDState = .floor
    @State private var idleTask: Task<Void, Never>? = nil
    /// Debounces the click-seek: rapid ±10s clicks accumulate a target and fire ONE
    /// engine seek after they settle. Per-click seeks thrash a transcode and wedge the
    /// player in `.waitingToPlayAtSpecifiedRate` (which the engine reports as playing,
    /// so play/pause then sticks). `pendingClickSeek` is the un-committed target.
    @State private var commitSeekTask: Task<Void, Never>? = nil
    @State private var pendingClickSeek: Double? = nil
    #endif
    @Environment(\.appIdiom) private var idiom
    #if DEBUG
    @State private var showDebugHUD = false
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let vm = viewModel {
                // The video host is mounted ONCE with stable identity across
                // .loading→.playing. Previously it lived inside both switch branches,
                // so the phase flip gave it a new identity and SwiftUI tore it down and
                // rebuilt it — which re-homed VLC's drawable mid-playback and left the
                // VLC path audio-only (AVKit survives the churn because AVPlayerLayer
                // reattaches seamlessly; VLC's injected render view does not). The
                // reload cover (showsReloadCover) hides it until the first frame.
                if showsVideoHost {
                    videoHost(vm)
                }
                switch vm.phase {
                case .idle, .loading:
                    EmptyView()
                case .playing:
                    SubtitleOverlayView(vm: vm)
                    #if os(tvOS)
                    tvPlaybackSurface(vm)
                    #else
                    PlayerControlsView(vm: vm, controlsVisible: $chromeVisible) { dismiss() }
                    #endif
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
                // `.title3` is oversized on the tvOS canvas; step it down and drop the
                // default tvOS button platter for a clean focus lift.
                .font(idiom == .tv ? .body : .title3)
                .foregroundStyle(.white.opacity(0.55))
                .tvChipButton()
                .padding(12)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showDebugHUD)
        #endif
        // No blanket .ignoresSafeArea() here: the black floor, video host, and reload
        // cover each opt into full-bleed individually (see above), while the chrome
        // (top bar, scrubber) and status bar respect the safe area. The status bar
        // hides in lockstep with the chrome.
        #if !os(tvOS)
        .statusBarHidden(!chromeVisible)
        #endif
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
                    engineFactory: deps.playbackEngineFactory,
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
            #if os(tvOS)
            idleTask?.cancel()
            commitSeekTask?.cancel()
            #endif
        }
        // The player is an immersive "screening room": pin the whole surface (video
        // host, controls, subtitle/loader/error/debug overlays) to dark appearance so
        // every bare `.glassEffect(.regular)` resolves to the same dark frosted
        // material regardless of the app's light/dark setting. Without this, in light
        // mode the large bottom scrubber panel picks up the light glass variant while
        // the small circle buttons barely show it, so they read as different palettes.
        // Outermost so `.overlay(...)` content (loader orb, debug HUD) inherits it;
        // matches the dark pin already on the track menus (`trackMenuChrome`).
        .environment(\.colorScheme, .dark)
    }

    /// True only while actively playing — gates the chrome-visibility reset above.
    private var isPlaybackActive: Bool {
        if case .playing = viewModel?.phase { return true }
        return false
    }

    /// Whether the persistent video host is mounted. Shown for every phase except
    /// `.failed` (which replaces the surface with the error overlay) — kept stable
    /// across .loading→.playing so VLC's drawable isn't rebuilt mid-playback.
    private var showsVideoHost: Bool {
        guard let vm = viewModel else { return false }
        if case .failed = vm.phase { return false }
        return true
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
                AVKitVideoLayerHost(engine: engine, onPiPReady: { start, stop in
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

    /// Intrinsic-width error pills can't use `formActionLabel` (it forces full width), so they
    /// reuse the shared tvOS control height directly.
    private var errorPillHeight: CGFloat { idiom == .tv ? AppLayout.tvControlHeight : 46 }

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
                        .padding(.horizontal, idiom == .tv ? Space.s40 : 24)
                        .frame(height: errorPillHeight)
                        .background(.white, in: Capsule())
                }
                // Custom chip style: gentle lift, no system focus platter (which `.plain`
                // paints around the pill on tvOS). Chrome is inside the label, so it scales whole.
                .tvChipButton()
                Button { dismiss() } label: {
                    Text("Close")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, idiom == .tv ? Space.s40 : 22)
                        .frame(height: errorPillHeight)
                        .glassEffect(.regular, in: Capsule())
                }
                .tvChipButton()
            }
            .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: 460)
    }

    #if os(tvOS)
    // MARK: - tvOS floor / swipe-scrub / full-HUD surface

    /// The tvOS playback surface: a raw remote-input adapter under the HUD, which is
    /// hidden on the floor, a minimal scrub bar while swipe-scrubbing, or the full
    /// chrome in `.fullHUD`. All input flows adapter → `send` → reducer → `apply`.
    @ViewBuilder
    private func tvPlaybackSurface(_ vm: PlayerViewModel) -> some View {
        ZStack {
            // The raw adapter owns the remote on the floor and during scrubbing. It's
            // unmounted in `.fullHUD` so the focus engine drives the chips/scrubber.
            if !isFullHUD {
                TVRemoteInputView(progressPerPoint: 0.00005, onEvent: { send($0, vm) })
                    .ignoresSafeArea()
            }

            // Dim the video while scrubbing so the lone progress bar reads clearly (the
            // design's brightness drop; saturation isn't feasible on a hardware layer).
            Color.black.opacity(isScrubbing ? 0.5 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.45), value: isScrubbing)

            switch hudState {
            case .floor:
                EmptyView()
            case .swipeScrub(let progress, _):
                tvScrubBar(progress: progress, vm: vm).transition(.opacity)
            case .clickSeek(let target):
                tvScrubBar(progress: target, vm: vm).transition(.opacity)
            case .fullHUD:
                PlayerControlsView(vm: vm, controlsVisible: .constant(true)) { dismiss() }
                    .transition(.opacity)
                    .onExitCommand { send(.menu, vm) }
            }
        }
        // Key on the whole HUD state, not just `isFullHUD`: the scrub bar's
        // `.transition(.opacity)` fires on floor↔swipeScrub↔clickSeek changes too, which
        // leave `isFullHUD` false — keying on it alone stranded those transitions (bar
        // snapped while the dim faded on its own clock).
        .animation(.easeInOut(duration: 0.2), value: hudState)
        // Dedicated Play/Pause button → reducer, in every HUD state.
        .onPlayPauseCommand { send(.playPause, vm) }
        // Start on the clean floor (chrome starts hidden).
        .onAppear { chromeVisible = false }
    }

    /// The lone lifted+grown progress bar shown during swipe-scrub / click-seek: chrome
    /// is gone, the video is dimmed, and this bar floats at the design's scrub height
    /// with a big time bubble + chapter ticks.
    @ViewBuilder
    private func tvScrubBar(progress: Double, vm: PlayerViewModel) -> some View {
        let m = PlayerMetrics.tv
        let dur = CMTimeGetSeconds(vm.currentDuration)
        let p = min(max(progress, 0), 1)
        let shown = p * dur
        let remaining = max(0, dur - shown)
        PlayerProgressBar(
            metrics: m, mode: .scrub, played: p,
            elapsed: formatPlaybackTime(shown),
            remaining: remaining > 0 ? "-\(formatPlaybackTime(remaining))" : formatPlaybackTime(dur),
            chapters: chapterFractions(vm, duration: dur),
            bubbleTime: formatPlaybackTime(shown),
            bubbleChapter: chapterTitle(vm, atSeconds: shown)
        )
        .padding(.horizontal, m.padX)
        .padding(.bottom, m.progressBottomScrub)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }

    /// Chapter start fractions (0...1) for the scrub ticks.
    private func chapterFractions(_ vm: PlayerViewModel, duration: Double) -> [Double] {
        guard duration > 0 else { return [] }
        return vm.chapters.map { chapter in
            let c = chapter.start.components
            let s = Double(c.seconds) + Double(c.attoseconds) / 1e18
            return min(max(s / duration, 0), 1)
        }
    }

    /// The chapter containing `atSeconds`, formatted "Chapter N · Name" for the bubble.
    /// Returns nil when the item has no chapters.
    private func chapterTitle(_ vm: PlayerViewModel, atSeconds: Double) -> String? {
        let chapters = vm.chapters
        guard !chapters.isEmpty else { return nil }
        func startSeconds(_ chapter: Chapter) -> Double {
            let c = chapter.start.components
            return Double(c.seconds) + Double(c.attoseconds) / 1e18
        }
        let current = chapters.last(where: { startSeconds($0) <= atSeconds }) ?? chapters[0]
        if let name = current.name, !name.isEmpty {
            return "Chapter \(current.index + 1) · \(name)"
        }
        return "Chapter \(current.index + 1)"
    }

    private var isFullHUD: Bool { if case .fullHUD = hudState { return true }; return false }
    /// The two transient scrub-bar states; only these arm the inactivity auto-hide.
    private var isScrubbing: Bool {
        switch hudState { case .swipeScrub, .clickSeek: return true; default: return false }
    }

    /// Feed a remote event through the reducer, apply its effects, sync the chrome
    /// flag, and restart the inactivity timer. The click-seek debounce lives here, not
    /// in the reducer: rapid clicks accumulate a target in `.clickSeek` and fire a
    /// single engine seek once they settle (or when the state leaves `.clickSeek`).
    private func send(_ event: RemoteEvent, _ vm: PlayerViewModel) {
        let leavingTarget: Double? = { if case .clickSeek(let t) = hudState { return t } else { return nil } }()
        let ctx = ReduceContext(
            liveProgress: tvProgress(of: vm),
            durationSeconds: CMTimeGetSeconds(vm.currentDuration),
            isPlaying: vm.isPlaying
        )
        let (next, effects) = reduce(hudState, event, ctx)

        // Commit/cancel a pending click-seek when leaving `.clickSeek`.
        if leavingTarget != nil {
            switch next {
            case .clickSeek: break              // still accumulating — keep debouncing
            case .swipeScrub: cancelClickSeek() // analog scrub takes over from the target
            default: flushClickSeek(vm)         // land the accumulated seek now
            }
        }

        hudState = next
        runEffects(effects, vm)

        // Entering or continuing `.clickSeek`: (re)arm the debounced commit.
        if case .clickSeek(let target) = next { scheduleClickSeek(to: target, vm) }

        chromeVisible = isFullHUD
        restartIdleTimer()
    }

    /// ~0.4s of quiet after the last click before the accumulated seek commits — long
    /// enough to fold a burst of clicks into one transcode seek, short enough to feel
    /// responsive. Tunable on device.
    private func scheduleClickSeek(to target: Double, _ vm: PlayerViewModel) {
        pendingClickSeek = target
        commitSeekTask?.cancel()
        commitSeekTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { flushClickSeek(vm) }
        }
    }

    /// Fire the single accumulated seek now and clear the pending target (so a later
    /// flush — e.g. from idle after the debounce already ran — is a no-op).
    private func flushClickSeek(_ vm: PlayerViewModel) {
        commitSeekTask?.cancel()
        guard let target = pendingClickSeek else { return }
        pendingClickSeek = nil
        runEffects([.seek(progress: target)], vm)
    }

    /// Drop the pending click-seek without committing (analog scrub will seek instead).
    private func cancelClickSeek() {
        commitSeekTask?.cancel()
        pendingClickSeek = nil
    }

    private func tvProgress(of vm: PlayerViewModel) -> Double {
        let dur = CMTimeGetSeconds(vm.currentDuration)
        guard dur > 0 else { return 0 }
        return min(max(CMTimeGetSeconds(vm.currentPosition) / dur, 0), 1)
    }

    /// Apply a transition's effects **in order, in a single task**, so an ordered pair
    /// like `[.seek, .play]` can't race: as detached per-effect tasks, `play()` could
    /// land before `seek()`, and a play-then-seek on a Jellyfin transcode parks AVPlayer
    /// in `.waitingToPlayAtSpecifiedRate` (reported as playing) — the resume is lost.
    private func runEffects(_ effects: [PlayerEffect], _ vm: PlayerViewModel) {
        guard !effects.isEmpty else { return }
        Task { for effect in effects { await apply(effect, vm) } }
    }

    private func apply(_ effect: PlayerEffect, _ vm: PlayerViewModel) async {
        switch effect {
        case .pause:
            await vm.engine?.pause()
        case .play:
            await vm.engine?.play()
        case .seek(let p):
            let dur = CMTimeGetSeconds(vm.currentDuration)
            guard dur > 0 else { return }
            let target = CMTime(seconds: p * dur, preferredTimescale: 600)
            await vm.engine?.seek(to: target)
        case .togglePlayPause:
            if vm.isPlaying { await vm.engine?.pause() } else { await vm.engine?.play() }
        case .exit:
            dismiss()
        }
    }

    /// Only the transient scrub bars auto-hide after inactivity. The floor needs no
    /// timer, and the full HUD is navigated with native focus (whose moves never reach
    /// `send`, so a timer there would hide the chrome mid-interaction) — Menu dismisses it.
    private func restartIdleTimer() {
        idleTask?.cancel()
        guard isScrubbing else { return }
        idleTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, let vm = viewModel { send(.idle, vm) }
        }
    }
    #endif
}
