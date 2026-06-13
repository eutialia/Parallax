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
    /// Build from a presenter request — the root hosts' shared entry point
    /// (`PlayerPresentationHost` on iOS, the tvOS full-screen cover).
    init(request: PlaybackPresenter.Request) {
        switch request.target {
        case .detail(let detail): self.init(item: detail, session: request.session)
        case .itemID(let itemID): self.init(itemID: itemID, session: request.session)
        }
    }

    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackPresenter.self) private var playback
    #if !os(tvOS)
    /// The host's presentation state (travel + settled flag) the pull gesture
    /// drives — injected by `PlayerPresentationHost`, the only iOS mount point.
    @Environment(PlayerPresentation.self) private var presentation
    #endif
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
    /// Mirror of the HUD's open-menu state (track panels / debug sheet). iOS: while
    /// a panel owns the screen, the pull-to-dismiss gesture stands down so a drag
    /// inside a list can't start dragging the whole player. tvOS: the full-HUD
    /// inactivity auto-hide is suspended — folding the chrome would take the open
    /// panel (and the debug sheet's mount point) with it.
    @State private var trackMenuOpen = false
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
    /// Last activity-driven idle re-arm — coalesces the ~60Hz pan stream (re-arming
    /// a multi-second timer per delta churns a cancel+Task each frame for nothing).
    @State private var lastActivityRearm: ContinuousClock.Instant? = nil
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
    /// One-shot suppression for the contextual Skip / Next Episode button: the segment
    /// id whose prompt has already shown (countdown elapsed, tapped, or revealed past).
    /// Shared by `PlayerSegmentPrompt`'s timer/tap and the tvOS `send` pipeline; cleared
    /// when the playhead leaves all segments so a re-entry re-arms.
    @State private var segmentPromptExpiredID: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            playbackSurface
        }
        // VoiceOver's two-finger double-tap toggles playback from anywhere on the surface.
        .accessibilityAction(.magicTap) { viewModel?.togglePlayPause() }
        // On the whole stack, floor included: the pull moves ONE layer — the
        // same unit the Close button's dismissal slides — not a card over a
        // parked backdrop (see PlayerPullToDismiss).
        #if !os(tvOS)
        // exclusionsActive: the scrub bar's no-pull zone only counts while the
        // chrome is hit-testable — hidden chrome leaves the whole surface as
        // the sheet handle.
        .playerPullToDismiss(
            presentation: presentation,
            isEnabled: !trackMenuOpen && !scrubHUDActive,
            exclusionsActive: chromeVisible
        ) { exitPlayer() }
        #endif
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
        // PAIRED PREDICATE: PlayerControlsView.statusBarExpectedVisible is the
        // exact negation of this expression. Its TopInsetLatch only adopts the
        // safe-area inset while the bar is expected visible — change one side
        // and the other must follow, or the top bars latch stale insets.
        .statusBarHidden(!chromeVisible || scrubHUDActive)
        // The pull-to-dismiss owns the top zone, so the first top-edge swipe
        // must be OURS — without this the notification-shade grabber steals
        // (cancels) the drag mid-pull. Same deferral AVPlayerViewController
        // applies in full screen; the shade stays one extra swipe away.
        .defersSystemGestures(on: .top)
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
        .task { await beginSession() }
        .onDisappear {
            // THE teardown point for every dismissal: exitPlayer() only pauses
            // (so the last frame rides the slide-out and the teardown's
            // main-thread burst can't eat its frames) and the host unmounts the
            // view once the dismissal lands — full stop() runs here. Also the
            // backstop for paths that never saw exitPlayer() (server switch,
            // the system tearing the tvOS cover down). stop() is idempotent.
            let vm = viewModel
            Task { await vm?.stop() }
            #if os(tvOS)
            idleTask?.cancel()
            commitSeekTask?.cancel()
            DisplayCriteriaMatcher.clear()
            #endif
        }
        // A movie / series finale that played to its end dismisses the player the same
        // way the Close chevron does (the VM flips `playbackDidComplete`); episodes
        // auto-advance instead and never set it.
        .onChange(of: viewModel?.playbackDidComplete) { _, done in
            if done == true { exitPlayer() }
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

    /// Builds the player's view model on first appearance and starts playback. One-shot
    /// (guarded on `viewModel == nil`): the `.task` can re-fire, but the session is built
    /// once. The model is wired with the per-session dependency factories (playback info,
    /// library repo) resolved here so they aren't captured before the session exists.
    private func beginSession() async {
        guard viewModel == nil else { return }
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
            fetchDetail: { try await repo.detail(for: $0) },
            rememberTrackSelection: { await info.rememberTrackSelection($0) },
            fetchSegments: { (try? await repo.mediaSegments(for: $0)) ?? [] },
            fetchAdjacent: { (try? await repo.adjacentEpisodes(seriesID: $0, episodeID: $1)) ?? .none }
        )
        viewModel = vm
        switch source {
        case .resolved(let item): await vm.start(item: item)
        case .unresolved(let id): await vm.start(itemID: id)
        }
    }

    /// Everything above the player's black floor — video host, veils, HUD, and
    /// overlays — as ONE concrete view, so the iOS pull-to-dismiss can move it
    /// as a single card (offset/scale/clip apply once, not per ZStack child).
    @ViewBuilder
    private var playbackSurface: some View {
        ZStack {
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
                                       onScrubActiveChange: { scrubHUDActive = $0 },
                                       onMenuOpenChange: { trackMenuOpen = $0 }) { exitPlayer() }
                    #endif
                    // Contextual Skip Intro/Recap · Next Episode button — a sibling
                    // layer ABOVE the chrome so it's independent of the auto-hide HUD
                    // (it shows over a clean frame on segment entry). iOS taps it
                    // directly; tvOS drives it through `send` (see `segmentButtonShowing`).
                    if playing {
                        PlayerSegmentPrompt(
                            vm: vm,
                            enabled: segmentPromptEnabled,
                            expiredSegmentID: $segmentPromptExpiredID,
                            onActivate: { activateSegmentPrompt(vm) }
                        )
                    }
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

    /// Exit on user intent: silence playback NOW, tear down AFTER the slide-out.
    /// `beginExit()` synchronously fences the in-flight start path (a mid-load
    /// exit can't resurrect playback) and `pause()` kills the audio on the spot —
    /// but the full `stop()` waits for `onDisappear`, once the dismiss animation
    /// has landed. Tearing down mid-slide unmounted the video host (the card went
    /// blank as it moved) and `replaceCurrentItem(nil)`'s synchronous main-thread
    /// burst ate dismissal frames — the "cut" slide-out. Pausing is the only
    /// urgent part; the engine and its last frame ride the card out.
    private func exitPlayer() {
        viewModel?.beginExit()
        let vm = viewModel
        Task { await vm?.engine?.pause() }
        #if os(tvOS)
        // Hand display-mode selection back to the system as the player leaves.
        DisplayCriteriaMatcher.clear()
        #endif
        // Through the presenter, not `\.dismiss`: on iOS the player is a root
        // overlay (no presentation to dismiss); on tvOS clearing the request
        // drives the cover's item binding to nil all the same.
        playback.dismiss()
    }

    /// True only while actively playing — gates the chrome-visibility reset above.
    private var isPlaybackActive: Bool {
        if case .playing = viewModel?.phase { return true }
        return false
    }

    /// Whether the contextual segment button may show. tvOS gates on the clean floor
    /// (revealing the HUD dismisses it); iOS hides it while a drag-scrub has collapsed
    /// the chrome into the lone bar (which owns the bottom edge and reads as clean).
    private var segmentPromptEnabled: Bool {
        #if os(tvOS)
        hudState == .floor
        #else
        !scrubHUDActive
        #endif
    }

    /// Whether the contextual segment button is on screen right now — derived from the
    /// SAME inputs as `PlayerSegmentPrompt.visible` (enabled · a current segment · not
    /// already dismissed), so `send` routes the floor remote to it off live state rather
    /// than a frame-late mirrored flag that could strand across an episode swap.
    private var segmentButtonShowing: Bool {
        guard let vm = viewModel else { return false }
        return segmentPromptEnabled && vm.activeSegmentID != nil && vm.activeSegmentID != segmentPromptExpiredID
    }

    /// Fire the active segment prompt — the shared action for the iOS tap and the tvOS
    /// remote's Select. Skip seeks past the intro/recap and keeps playing; Next Episode
    /// advances. No-op when nothing's active. One-shot-dismisses the button up front so
    /// it hides on the press, not a frame later when the seek/reload lands.
    private func activateSegmentPrompt(_ vm: PlayerViewModel) {
        switch vm.segmentPrompt {
        case .skip: Task { await vm.skipActiveSegment() }
        case .nextEpisode: Task { await vm.playNextEpisode() }
        case nil: return
        }
        segmentPromptExpiredID = vm.activeSegmentID
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
                label: viewModel?.loaderTitle ?? "Loading video",
                sublabel: viewModel?.loaderSubtitle,
                metrics: .forSurface(geo.size)
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
                metrics: .forSurface(geo.size)
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
                metrics: .forSurface(geo.size)
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
            // gates what reaches the reducer per state. `onActivity` feeds the
            // inactivity timer with EVERY observed pan/press — including the
            // focus-engine interactions in `.fullHUD` that never reach `send` —
            // so the full HUD can auto-hide without hiding mid-interaction.
            TVPanCatcher(progressPerPoint: 0.00005,
                         onActivity: { noteRemoteActivity() }) { onPan($0, vm) }
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

            // Paused status — dim + flat center glyph. Mounted for the whole eligible
            // window (floor playback, not scrubbing/stalling) and fed the live pause
            // intent; the overlay owns its glyph lifecycle (pause in → hold → play morph
            // → close) so a resume gets a play-glyph beat instead of a hard cut. On the
            // floor it brings its own dim; in .fullHUD the controls scrim already dims, so
            // only the glyph rides (stacked dims read as a brightness glitch).
            if pausedScrimEligible(vm) {
                PlayerPausedOverlay(metrics: .tv, dimmed: !isFullHUD, isPaused: !vm.isPlaying)
                    .transition(.opacity)
            }

            switch hudState {
            case .floor:
                EmptyView()
            // One pattern, one view identity: swipeScrub↔clickSeek must NOT cross-fade
            // two bars — the shared bar just retargets its progress (animated below).
            case .swipeScrub(let progress, _), .clickSeek(targetProgress: let progress):
                tvScrubBar(progress: progress, vm: vm).transition(.opacity)
            case .fullHUD:
                // Back handling lives INSIDE the controls (one root handler that
                // closes an open panel before folding); `onExitHUD` is the no-menu
                // branch. The menu mirror gates the idle timer: cancel under an
                // open panel, re-arm when it closes.
                PlayerControlsView(vm: vm, controlsVisible: .constant(true),
                                   debugHUD: $showDebugHUD,
                                   onScrubberFocusChange: { scrubberHasFocus = $0 },
                                   onActivity: { noteRemoteActivity() },
                                   onMenuOpenChange: { open in
                                       trackMenuOpen = open
                                       if open { idleTask?.cancel() } else { restartIdleTimer() }
                                   },
                                   onExitHUD: { send(.menu, vm) }) { exitPlayer() }
                    .transition(.opacity)
                    // The mirror can go stale when the controls unmount with a panel
                    // up (phase → .failed swaps in the error overlay): a remount
                    // starts with no menu but `trackMenuOpen` stuck true would
                    // suspend the auto-hide for the rest of the session.
                    .onDisappear { trackMenuOpen = false }
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
        // Fast ease-out so a Menu press mid-reveal feels instant — the chrome is
        // opacity-driven and the animation retargets from its current value.
        .animation(.easeOut(duration: 0.15), value: isFullHUD)
        .animation(.easeInOut(duration: 0.2), value: viewModel?.isPlaying ?? true)
        // …and the stall scrim's arrival, so a paused→stall flip fades the paused
        // glyph out instead of popping it (review-found).
        .animation(.easeInOut(duration: 0.2), value: viewModel?.showsStallScrim ?? false)
        // Dedicated Play/Pause button → reducer, in every HUD state.
        .onPlayPauseCommand { send(.playPause, vm) }
        // Pause pins the full HUD (the auto-hide guard reads isPlaying); resuming
        // re-arms it. Engine beats flip isPlaying async, so the pause side must
        // also cancel a timer armed a beat earlier. Full-HUD only: swipe-scrub
        // pauses the engine BY DESIGN and its 1s commit timer must keep running.
        .onChange(of: vm.isPlaying) { _, playing in
            guard isFullHUD else { return }
            if playing { restartIdleTimer() } else { idleTask?.cancel() }
        }
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

    /// Whether the paused-status overlay is RELEVANT (mounted): the surface is live on
    /// the floor, not scrubbing, not stalling. Whether it actually paints — and the
    /// pause→hold→play→close lifecycle — is the overlay's own call off `isPaused`, so it
    /// must survive the resume (hence this drops the old `!isPlaying` term that used to
    /// unmount it the instant playback resumed). Suppressed in `.fullHUD`: the centre
    /// transport's own play/pause glyph stands in there, so a second centred mark would
    /// double up. Also suppressed once `playbackDidComplete`: a finale/movie ends with
    /// `phase` still `.playing` (no `.loading` swap, since nothing advances), and this
    /// view is about to dismiss — without the term the pause glyph would flash through
    /// the exit slide.
    private func pausedScrimEligible(_ vm: PlayerViewModel) -> Bool {
        vm.phase == .playing && !isScrubbing && !vm.showsStallScrim && !isFullHUD && !vm.playbackDidComplete
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
        // While the contextual segment button shows over the floor, the remote acts
        // on IT — the floor adapter already holds focus, so there's no competing
        // focusable. Select fires the prompt (skip / next episode); any directional
        // reveal lifts the HUD and one-shot-dismisses the button (it won't re-summon
        // on return until the playhead re-enters the segment). Back still exits and an
        // analog pan still scrubs, so neither is intercepted here.
        if hudState == .floor, segmentButtonShowing, vm.phase == .playing {
            switch event {
            case .select:
                activateSegmentPrompt(vm)
                restartIdleTimer()
                return
            case .click, .swipeVertical:
                segmentPromptExpiredID = vm.activeSegmentID
                hudState = .fullHUD
                scrubberHasFocus = false
                chromeVisible = true
                restartIdleTimer()
                return
            case .swipeHorizontal, .menu, .playPause, .idle:
                break
            }
        }

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

    /// The quiet-time before a scrub auto-commits, SHARED by ±10s click-seek (this
    /// debounce) and analog swipe-scrub (the `.swipeScrub` idle in `restartIdleTimer`),
    /// so both resume the same delay after you stop. Long enough to fold a click burst
    /// into one transcode seek, short enough to feel responsive. Tunable on device.
    private static let scrubCommitDelay: Duration = .milliseconds(400)

    private func scheduleClickSeek(to target: Double, _ vm: PlayerViewModel) {
        pendingClickSeek = target
        commitSeekTask?.cancel()
        commitSeekTask = Task {
            try? await Task.sleep(for: Self.scrubCommitDelay)
            guard !Task.isCancelled, let dest = pendingClickSeek else { return }
            pendingClickSeek = nil
            // Commit the ONE coalesced seek, then drop the bar the moment it lands —
            // the click-seek bar used to ride the 4s `.clickSeek` idle timeout even after
            // playback had already resumed at the new spot (user-reported lingering). The
            // timeout stays only as a safety net if this task is cancelled mid-flight.
            await apply(.seek(progress: dest), vm)
            guard !Task.isCancelled, case .clickSeek = hudState else { return }
            send(.idle, vm)
        }
    }

    /// Fire the single accumulated seek NOW and clear the pending target. Used by the
    /// `send` leave-early path (the user navigates out of `.clickSeek` before the 400ms
    /// debounce); the natural debounce path commits AND drops the bar in
    /// `scheduleClickSeek` instead. A later flush with nothing pending is a no-op.
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
            // Optimistic flip inside the vm — the paused overlay reacts on the
            // press, not a beat later, and remote-press spam coalesces to the
            // last intent. The reducer's .pause/.play effects above keep
            // commanding the engine directly (they carry wasPlaying intent).
            vm.togglePlayPause()
        case .exit:
            exitPlayer()
        }
    }

    /// Per-state inactivity timer. Swipe-scrub commits ~1s after the touch goes
    /// quiet (the reducer's `.idle` seeks and resumes — no Select required); the
    /// click-seek bar lingers longer (its seek already landed via the 400ms click
    /// debounce — idle only drops the bar). The full HUD auto-hides after 4s of no
    /// remote interaction: focus-engine moves never reach `send`, so the reset
    /// signal is `TVPanCatcher.onActivity` (window-level pans + presses, observed
    /// in every focus state). Suspended while a panel is open (folding would
    /// unmount it) or playback is paused (the iOS rule — vanishing chrome over a
    /// frozen frame reads as a dead player). The floor needs no timer.
    /// Activity from the window-level observers, coalesced to ~4 re-arms/s: a pan
    /// streams a delta per frame, and the slop this adds (<250ms against multi-second
    /// timeouts) is invisible — reducer-driven `send` still re-arms exactly.
    private func noteRemoteActivity() {
        let now = ContinuousClock.now
        if let last = lastActivityRearm, now - last < .milliseconds(250) { return }
        lastActivityRearm = now
        restartIdleTimer()
    }

    private func restartIdleTimer() {
        idleTask?.cancel()
        let timeout: Duration
        switch hudState {
        case .floor:
            return
        case .swipeScrub:
            timeout = Self.scrubCommitDelay   // same 0.4s as the click-seek debounce

        case .clickSeek:
            timeout = .seconds(4)
        case .fullHUD:
            guard !trackMenuOpen, viewModel?.isPlaying == true else { return }
            timeout = .seconds(4)
        }
        idleTask = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled, let vm = viewModel { send(.idle, vm) }
        }
    }
    #endif
}
