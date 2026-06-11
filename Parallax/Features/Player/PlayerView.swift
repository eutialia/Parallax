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
    /// Set at the first `.playing` beat. The initial-load chrome (fullHUD over
    /// the loading scrim — iOS parity) hands off to the reducer's clean floor
    /// exactly once; later loading dips (track-switch re-buffers) keep whatever
    /// HUD state the user is in, so an open menu survives the swap.
    @State private var didBeginPlayback = false
    #endif
    /// Unconditional so the binding can thread into `PlayerControlsView`'s chip
    /// row without forking its initializer per build config; everything that
    /// RENDERS from it (the chip, the overlay) stays `#if DEBUG`.
    @State private var showDebugHUD = false

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
                    // One surface identity from .idle through .playing (the video
                    // host's lesson above): the HUD is live while the stream resolves
                    // — the full chrome shows over the loading scrim (Close focusable,
                    // chips populate as their lists arrive), Back exits immediately,
                    // and a track-switch re-buffer no longer tears down the surface
                    // (and any open menu) mid-switch. Engine-backed remote events are
                    // gated in `send` until .playing.
                    tvPlaybackSurface(vm)
                    #else
                    // One identity from loading through playing (the video host's
                    // lesson above): the HUD is live the moment the player appears —
                    // tap-to-toggle, Close in its real spot, and the track chips as
                    // soon as their lists populate. Engine-backed transport is gated
                    // inside on vm.phase, so nothing inert looks tappable.
                    PlayerControlsView(vm: vm, controlsVisible: $chromeVisible,
                                       debugHUD: $showDebugHUD,
                                       onScrubActiveChange: { scrubHUDActive = $0 }) { exitPlayer() }
                    #endif
                    // A failed audio switch that fell back to the previous track:
                    // playback continues underneath; the scrim offers retry / keep.
                    if playing, let failure = vm.trackSwitchFailure {
                        trackSwitchFailureOverlay(failure, vm: vm)
                            .transition(.opacity)
                    }
                case .failed(let error):
                    errorOverlay(error, vm: vm)
                }
            } else {
                // Pre-VM beat (dependency factories resolving) — veil only.
                loadingVeil
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showsReloadCover)
        .animation(.easeInOut(duration: 0.3), value: viewModel?.trackSwitchFailure != nil)
        // The debug panel presents from the HUD's chip row (PlayerControlsView)
        // like the track menus — a corner overlay was unreachable (and its
        // ScrollView unscrollable) by the tvOS focus engine.
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
        // re-mounts the controls already visible. iOS-only: on tvOS the surface's
        // phase hand-off owns chromeVisible (mirroring hudState), and forcing it
        // true here would desync it from the floor.
        #if !os(tvOS)
        .onChange(of: isPlaybackActive) { _, active in
            if !active { chromeVisible = true }
        }
        #endif
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
            DisplayCriteriaMatcher.clear()
            #endif
        }
        // The player is an immersive "screening room": pin the whole surface (video
        // host, controls, subtitle/loader/error/debug overlays) to dark appearance so
        // every bare `.glassEffect(.regular)` resolves to the same dark frosted
        // material regardless of the app's light/dark setting. Without this, in light
        // mode the large bottom scrubber panel picks up the light glass variant while
        // the small circle buttons barely show it, so they read as different palettes.
        // Outermost so `.overlay(...)` content (loading scrim, debug HUD) inherits it;
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
        #if os(tvOS)
        // Hand display-mode selection back to the system as the player leaves.
        DisplayCriteriaMatcher.clear()
        #endif
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

    /// Loading visual: a calm monochrome scrim over the video surface — a dim wash
    /// with the white indeterminate ring — NOT a frosted blocking pill: hit testing
    /// is off, so the HUD layered above stays fully interactive while the stream
    /// resolves/buffers. On a transcode track switch the engine is paused + reused,
    /// so the last frame stays under the lighter audio-switch dim until the new
    /// stream plays; on a first play the field is the black floor.
    private var loadingVeil: some View {
        GeometryReader { geo in
            PlayerLoadingScrim(
                mode: scrimFlavor,
                label: viewModel?.loaderTitle ?? "Loading",
                sublabel: viewModel?.loaderSubtitle,
                metrics: scrimMetrics(width: geo.size.width)
            )
        }
        // Full-bleed like the video host: the chrome toggles the status bar and
        // home indicator, and a safe-area-bounded veil would shift its centred
        // ring a few points every time the HUD shows/hides.
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private var scrimFlavor: PlayerLoadingScrim.Mode {
        guard let vm = viewModel else { return .coldStart }
        return vm.isSwitchingTracks || vm.showsStallScrim ? .liveFrame : .coldStart
    }

    /// Scrim scale: big screens derive the unit from the surface width (the same
    /// 1920 base as the chrome); iPhone uses the fixed `.phone` scale — mirroring
    /// `PlayerControlsView`'s device-based split.
    private func scrimMetrics(width: CGFloat) -> PlayerMetrics {
        #if os(tvOS)
        return .tv
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? PlayerMetrics(width: width) : .phone
        #endif
    }

    /// Whether to show the loading veil: before the VM exists, while it's
    /// idle/loading (initial load and a track-switch re-buffer), and during a
    /// mid-stream stall (debounced — the light "Buffering" flavor over the
    /// frozen frame). Hidden when playing healthily or failed.
    private var showsReloadCover: Bool {
        guard let vm = viewModel else { return true }
        switch vm.phase {
        case .idle, .loading: return true
        case .playing: return vm.showsStallScrim
        case .failed: return false
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

    /// Fatal failure: the general playback error scrim ("Playback stopped"), with
    /// the raw diagnostics in a monospace support block. White-on-dark over the
    /// black player surface (the overlay pins dark, so the native Liquid Glass
    /// buttons resolve white-on-dark regardless of the app theme).
    @ViewBuilder
    private func errorOverlay(_ error: AppError, vm: PlayerViewModel) -> some View {
        GeometryReader { geo in
            PlayerErrorScrim(
                title: "Playback stopped",
                message: error.userMessage,
                details: error.diagnosticDescription,
                metrics: scrimMetrics(width: geo.size.width)
            ) {
                Button("Try again", systemImage: "arrow.clockwise") { Task { await vm.retry() } }
                    .buttonStyle(.glassProminent)
                    .tint(.white)
                #if !os(tvOS)
                // tvOS has no pasteboard; elsewhere the raw block is one tap from a
                // bug report.
                Button("Copy details") { UIPasteboard.general.string = error.diagnosticDescription }
                    .buttonStyle(.glass)
                #endif
                Button("Close") { exitPlayer() }
                    .buttonStyle(.glass)
            }
        }
        #if os(tvOS)
        // Back mirrors the Close pill. Focus sits on the buttons, so this rides the
        // focused responder chain (a sibling input adapter would never see Menu).
        .onExitCommand { exitPlayer() }
        #endif
    }

    /// Non-fatal failure: an audio-track switch died but playback already fell back
    /// to the previous track (the design's silent fallback) — this scrim is the loud
    /// part, offering a retry. Mounted ABOVE the chrome so its buttons are tappable,
    /// but its dim passes touches through, so the scrubber and menus stay live.
    @ViewBuilder
    private func trackSwitchFailureOverlay(
        _ failure: PlayerViewModel.TrackSwitchFailure, vm: PlayerViewModel
    ) -> some View {
        GeometryReader { geo in
            PlayerErrorScrim(
                title: "Couldn't switch audio",
                message: switchFailureMessage(failure),
                metrics: scrimMetrics(width: geo.size.width)
            ) {
                Button("Try again", systemImage: "arrow.clockwise") {
                    Task { await vm.retryFailedTrackSwitch() }
                }
                .buttonStyle(.glassProminent)
                .tint(.white)
                Button("Keep current track") { vm.dismissTrackSwitchFailure() }
                    .buttonStyle(.glass)
            }
        }
        #if os(tvOS)
        // Back = "Keep current track" — dismiss without killing playback.
        .onExitCommand { vm.dismissTrackSwitchFailure() }
        #endif
    }

    private func switchFailureMessage(_ failure: PlayerViewModel.TrackSwitchFailure) -> String {
        let stayed = failure.fallback.map { "Playback stayed on \($0.displayName)" }
            ?? "Playback continues on the previous track"
        return "The \(failure.requested.displayName) source didn't respond. \(stayed) — nothing was lost."
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
            // chips/scrubber — and while the switch-failure scrim shows, so its
            // buttons can take focus (a mounted adapter would swallow Select/Menu).
            if !isFullHUD && vm.trackSwitchFailure == nil {
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
                                   debugHUD: $showDebugHUD,
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
        // Fresh surface: the initial load shows the full chrome over the scrim
        // (iOS parity — the player is operable while the stream resolves); once
        // playback has begun (a post-failure retry remount), start on the clean
        // floor. Clear any click-seek debris a previous mount left armed.
        .onAppear {
            hudState = didBeginPlayback ? .floor : .fullHUD
            cancelClickSeek()
            chromeVisible = isFullHUD
        }
        // Phase transitions own the HUD floor hand-offs:
        // • first .playing — the loading chrome drops to the reducer's clean
        //   floor (re-buffers keep their HUD state, see `didBeginPlayback`);
        // • leaving .playing (re-buffer / failure) — a scrub state would strand
        //   a frozen bar plus armed idle/commit timers over the scrim, and its
        //   duration context is stale mid-reload; fold to the floor and drop
        //   the pending seek.
        .onChange(of: vm.phase == .playing) { _, nowPlaying in
            if nowPlaying {
                if !didBeginPlayback {
                    didBeginPlayback = true
                    if isFullHUD {
                        hudState = .floor
                        // Same stale-mirror clear as send(): the HUD unmount may
                        // never fire the focus callback with `false`.
                        scrubberHasFocus = false
                    }
                }
            } else {
                cancelClickSeek()
                idleTask?.cancel()
                if isScrubbing { hudState = .floor }
            }
            chromeVisible = isFullHUD
        }
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
            metrics: m, mode: .scrub, played: p, buffered: vm.bufferedFraction,
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
        // Pre-playback (initial load and a track-switch re-buffer): only chrome
        // reveal, exit, and idle are meaningful. Transport/seek events are
        // dropped at the door — mid-reload the engine is being fed a new asset
        // and `currentDuration` is stale, so a seek/play would land on a dead or
        // mid-swap stream. The reducer itself stays phase-blind.
        if vm.phase != .playing {
            switch event {
            case .menu where !didBeginPlayback:
                // First load: Back exits immediately (synchronously fencing the
                // in-flight resolve) instead of peeling the loading chrome back
                // to an empty floor.
                exitPlayer()
                return
            case .swipeVertical, .click(.up), .click(.down), .menu, .idle:
                break
            case .swipeHorizontal, .click(.left), .click(.right), .select, .playPause:
                return
            }
        }

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
    ///
    /// `.exit` is pulled out and run synchronously with the press: `beginExit()`
    /// must arm its fence before a suspended start-path continuation can
    /// interleave, and the one-hop Task below is exactly that window.
    private func runEffects(_ effects: [PlayerEffect], _ vm: PlayerViewModel) {
        guard !effects.isEmpty else { return }
        if effects.contains(.exit) { exitPlayer() }
        let engineEffects = effects.filter { $0 != .exit }
        guard !engineEffects.isEmpty else { return }
        Task { for effect in engineEffects { await apply(effect, vm) } }
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
