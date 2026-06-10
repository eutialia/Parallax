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
    #if !os(tvOS)
    /// True while a finger drags the scrub bar — `PlayerControlsView` has collapsed
    /// the chrome into the lone scrub bar (the iOS analog of tvOS swipe-scrub), so
    /// the status bar and home indicator hide with it.
    @State private var scrubHUDActive = false
    #endif
    #if os(tvOS)
    /// The tvOS HUD floor state machine (floor → swipeScrub → clickSeek → fullHUD),
    /// driven by `TVRemoteInputView` through `send(_:_:)`. See `PlayerHUDReducer`.
    @State private var hudState: PlayerHUDState = .floor
    @State private var idleTask: Task<Void, Never>? = nil
    /// Mirrors the full-HUD scrubber's focus (reported by `PlayerControlsView`) —
    /// gates window-level pans into analog scrub; on any other focused control a
    /// swipe stays with the focus engine, same as a click.
    @State private var scrubberHasFocus = false
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
                // Under the chrome, over the video: visual only (hit testing off),
                // so loading never blocks the HUD mounted below.
                if showsReloadCover {
                    loadingVeil
                }
                switch vm.phase {
                case .idle, .loading, .playing:
                    let playing = vm.phase == .playing
                    if playing {
                        SubtitleOverlayView(vm: vm)
                    }
                    #if os(tvOS)
                    if playing {
                        tvPlaybackSurface(vm)
                    } else {
                        // Loading must be escapable: nothing else focusable is mounted
                        // before playback, so this adapter holds focus and catches Menu
                        // — Back exits immediately, cancelling the in-flight resolve.
                        TVRemoteInputView(onEvent: { event in
                            if case .menu = event { exitPlayer() }
                        })
                        .ignoresSafeArea()
                    }
                    #else
                    // One identity from loading through playing (the video host's
                    // lesson above): the HUD is live the moment the player appears —
                    // tap-to-toggle, Close in its real spot, and the track chips as
                    // soon as their lists populate. Engine-backed transport is gated
                    // inside on vm.phase, so nothing inert looks tappable.
                    PlayerControlsView(vm: vm, controlsVisible: $chromeVisible,
                                       onScrubActiveChange: { scrubHUDActive = $0 }) { exitPlayer() }
                    #endif
                case .failed(let error):
                    errorOverlay(error, vm: vm)
                }
            } else {
                // Pre-VM beat (dependency factories resolving) — veil only.
                loadingVeil
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
        .statusBarHidden(!chromeVisible || scrubHUDActive)
        #endif
        .persistentSystemOverlays(systemOverlaysVisible ? .automatic : .hidden)
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
            // Backstop for dismissals that didn't route through exitPlayer()
            // (e.g. the system tearing the cover down). stop() is idempotent.
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

    /// System overlays (home indicator) follow the chrome — and on iOS also hide
    /// during a drag-scrub, whose collapsed HUD reads as a clean screen.
    private var systemOverlaysVisible: Bool {
        #if os(tvOS)
        chromeVisible
        #else
        chromeVisible && !scrubHUDActive
        #endif
    }

    /// Exit on user intent: halt playback NOW — `beginExit()` synchronously fences
    /// the in-flight start path (a mid-load exit can't resurrect playback), and
    /// stop() pauses + tears the engine down while the dismiss animation is still
    /// running. Waiting for `onDisappear` alone meant ~half a second of audio
    /// bleeding past the dismissal, and no cancellation at all during loading.
    private func exitPlayer() {
        viewModel?.beginExit()
        let vm = viewModel
        Task { await vm?.stop() }
        dismiss()
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

    /// Loading visual: the video surface itself becomes the loader. The picture calms
    /// to a dark field and a liquid-glass orb takes center — NOT a frosted blocking
    /// pill: hit testing is off, so the HUD layered above stays fully interactive
    /// while the stream resolves/buffers. On a transcode track switch the engine is
    /// paused + reused, so the last frame stays under the calm scrim until the new
    /// stream plays; on a first play the field is the black floor.
    private var loadingVeil: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            if let vm = viewModel {
                LoaderOrb(label: vm.loaderTitle, sublabel: vm.loaderSubtitle)
            } else {
                LoaderOrb()
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    /// Whether to show the loading veil: before the VM exists and while it's
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

    /// Failure state. White-on-dark over the black player surface (so it ignores the
    /// app's light/dark tint — the old `.borderedProminent` Retry rendered white-on-
    /// white under the monochrome global tint). Solid-white "Try Again", glass "Close".
    @ViewBuilder
    private func errorOverlay(_ error: AppError, vm: PlayerViewModel) -> some View {
        VStack(spacing: Space.s16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .glassEffect(.regular, in: Circle())
                .accessibilityHidden(true)
            Text("Playback failed")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
            Text(error.userMessage)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
            // Native Liquid Glass buttons: prominent white Try Again, plain glass Close.
            // The system owns sizing and the tvOS focus treatment; the overlay pins dark,
            // so both resolve white-on-dark regardless of the app theme.
            HStack(spacing: Space.s12) {
                Button("Try Again") { Task { await vm.retry() } }
                    .buttonStyle(.glassProminent)
                    .tint(.white)
                Button("Close") { exitPlayer() }
                    .buttonStyle(.glass)
            }
            .font(.headline)
            .padding(.top, Space.s8)
        }
        .padding(Space.s40)
        .frame(maxWidth: 460)
        #if os(tvOS)
        // Back mirrors the Close pill. Focus sits on the chips, so this rides the
        // focused responder chain (a sibling input adapter would never see Menu).
        .onExitCommand { exitPlayer() }
        #endif
    }

    #if os(tvOS)
    // MARK: - tvOS floor / swipe-scrub / full-HUD surface

    /// The tvOS playback surface: a raw remote-input adapter under the HUD, which is
    /// hidden on the floor, a minimal scrub bar while swipe-scrubbing, or the full
    /// chrome in `.fullHUD`. All input flows adapter → `send` → reducer → `apply`.
    @ViewBuilder
    private func tvPlaybackSurface(_ vm: PlayerViewModel) -> some View {
        ZStack {
            // Analog pans are captured at the window level in EVERY state (one
            // recognizer for the surface's lifetime, so an in-flight pan keeps
            // streaming deltas across floor↔scrub↔fullHUD transitions). `onPan`
            // gates what reaches the reducer per state.
            TVPanCatcher(progressPerPoint: 0.00005) { onPan($0, vm) }
                .allowsHitTesting(false)

            // The raw adapter owns the remote's PRESSES on the floor and during
            // scrubbing. It's unmounted in `.fullHUD` so the focus engine drives the
            // chips/scrubber.
            if !isFullHUD {
                TVRemoteInputView(onEvent: { send($0, vm) })
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
            // One pattern, one view identity: swipeScrub↔clickSeek must NOT cross-fade
            // two bars — the shared bar just retargets its progress (animated below).
            case .swipeScrub(let progress, _), .clickSeek(targetProgress: let progress):
                tvScrubBar(progress: progress, vm: vm).transition(.opacity)
            case .fullHUD:
                PlayerControlsView(vm: vm, controlsVisible: .constant(true),
                                   onScrubberFocusChange: { scrubberHasFocus = $0 }) { exitPlayer() }
                    .transition(.opacity)
                    .onExitCommand { send(.menu, vm) }
            }
        }
        // Key the cross-fades on the state KIND, not the whole `hudState`: `swipeScrub`
        // and `clickSeek` carry the scrub progress, so keying on the full value re-ran
        // this 0.2s ease on every swipe delta — the bar chased each frame and the time
        // text cross-faded continuously. The two flags cover every kind change
        // (floor↔scrub flips `isScrubbing`, scrub↔HUD flips both, floor↔HUD flips
        // `isFullHUD`), and swipeScrub↔clickSeek shares one bar identity above, so it
        // needs no transition at all.
        .animation(.easeInOut(duration: 0.2), value: isScrubbing)
        .animation(.easeInOut(duration: 0.2), value: isFullHUD)
        // Dedicated Play/Pause button → reducer, in every HUD state.
        .onPlayPauseCommand { send(.playPause, vm) }
        // Start on the clean floor (chrome starts hidden).
        .onAppear { chromeVisible = false }
    }

    /// The lone progress bar shown during swipe-scrub / click-seek: chrome is gone,
    /// the video is dimmed, and a big time bubble + chapter ticks appear. It shares
    /// the full-HUD scrubber's exact geometry (inset, track, labels, row height) so
    /// the floor↔HUD switch reads as one persistent bar, not a jump-cut.
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
            elapsedSeconds: shown,
            remainingSeconds: remaining,
            chapters: vm.chapterFractions,
            bubbleTime: formatPlaybackTime(shown),
            bubbleChapter: vm.chapterTitle(atSeconds: shown)
        )
        // One snappy spring for both scrub flavors: a ±10s click-seek step glides to
        // its target instead of snapping, and swipe deltas retarget the same spring
        // for smooth analog tracking (with rolling digits via `.numericText`).
        .animation(.snappy(duration: 0.25, extraBounce: 0), value: p)
        .padding(.horizontal, m.padX)
        .padding(.bottom, m.progressBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }

    private var isFullHUD: Bool { if case .fullHUD = hudState { return true }; return false }
    /// The two transient scrub-bar states; only these arm the inactivity auto-hide.
    private var isScrubbing: Bool {
        switch hudState { case .swipeScrub, .clickSeek: return true; default: return false }
    }

    /// Window-level pan events. On the floor / scrub states every pan drives the
    /// reducer. In `.fullHUD` native focus owns navigation — only a horizontal pan
    /// while the scrubber holds focus falls through (collapsing the chrome into
    /// analog scrub); everything else stays with the focus engine, so a swipe on a
    /// chip still just moves the highlight.
    private func onPan(_ event: RemoteEvent, _ vm: PlayerViewModel) {
        if isFullHUD {
            guard scrubberHasFocus, case .swipeHorizontal = event else { return }
        }
        send(event, vm)
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
        // The focus mirror only matters in `.fullHUD`; clear it on the way out because
        // unmounting the HUD may never fire the focus callback with `false`, and a
        // stale `true` would route a later pan through the fullHUD gate.
        if !isFullHUD { scrubberHasFocus = false }
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
            exitPlayer()
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
