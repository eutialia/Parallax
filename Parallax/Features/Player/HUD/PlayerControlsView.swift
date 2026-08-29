import SwiftUI
import AVKit
import CoreMedia
import ParallaxPlayback

/// Engine-agnostic player chrome, overlaid on the video host as independent
/// edge-anchored overlays (top bar · centre transport · progress · control row) — no
/// wrapping glass panel; legibility comes from the scrim. Reads `PlayerViewModel` state
/// and drives transport, scrubbing, track selection, and speed.
///
/// The chrome is always white-on-dark (an immersive "screening room" over video). It
/// uses explicit `.white` and bare Liquid Glass rather than the light/dark tokens, and
/// `PlayerView` pins the whole surface to `.dark` so the glass resolves consistently.
///
/// Big screens (tvOS + iPad) scale every size from `PlayerMetrics(width:)`; iPhone uses
/// the fixed `.phone` set with the `phone*` round-button statics. tvOS keeps the centre
/// transport (the full HUD holds play/pause up so it can't blink out under scrubber
/// nudges — see `showsCenterTransport`) but drops the AirPlay/PiP pill (unavailable on
/// tvOS). Touch chrome follows the TV app's player: Close top-left (the
/// Music-style collapse corner), the AirPlay/PiP pill top-right, chips + scrubber
/// alone at the bottom. (The HIG's "AirPlay lower-right" line lost to Apple's own TV
/// app, which clusters these accessories at the top — and the bottom row needed the
/// room once the controls grew to TV-app scale.) tvOS keeps Close in the bottom
/// control row: its real exit is the remote's Back, and the chevron stays near the
/// scrubber's focus geography.
///
/// Controls auto-hide after 3s of inactivity on iOS (suspended while a menu is open
/// or playback is paused); tap anywhere to toggle — instantly, every tap. Double-tap the
/// outer thirds to skip ±10s: the `PlayerSeekFlash` dome is the affordance and the shared
/// `PlayerScrubBar` rides its bottom, and the pair's second tap HIDES the chrome so the
/// HUD never conflicts with them — see `handleTap`. tvOS visibility is owned by the HUD
/// reducer in `PlayerView` (this view is mounted only in `.fullHUD`).
///
/// On iOS the chrome is mounted from `.loading` onward — the player is operable while
/// the stream resolves/buffers (Close, tap-to-toggle, track chips as their lists
/// populate). Engine-backed transport gates on `playbackReady`.
struct PlayerControlsView: View {
    @Bindable var vm: PlayerViewModel
    /// Chrome visibility, owned by `PlayerView` so it can also drive the status bar.
    @Binding var controlsVisible: Bool
    /// Debug-HUD visibility, owned by `PlayerView` (the overlay must outlive the
    /// chrome's auto-hide). Toggled from the chip row — DEBUG builds only render
    /// the chip; a corner overlay button was unreachable by the tvOS focus engine.
    @Binding var debugHUD: Bool
    #if os(tvOS)
    /// Reports the scrub bar's focus to `PlayerView`, which gates window-level pans
    /// into analog scrub only while the bar is focused. Required, not optional —
    /// without the wiring, swipe-on-scrubber silently degrades to click-stepping.
    let onScrubberFocusChange: (Bool) -> Void
    /// Reports HUD interaction (focus moving between scrubber/chips, panel work) up to
    /// `PlayerView` so its inactivity timer re-arms. In `.fullHUD` the raw press adapter
    /// is unmounted and focus-engine navigation never reaches `send`; directional CLICKS
    /// also slip past the window-level press sentinel that otherwise feeds the timer — so
    /// without this the chrome auto-hid mid-navigation (user-reported).
    let onActivity: () -> Void
    #else
    /// Reports drag-scrub activity to `PlayerView`, which hides the status bar and
    /// home indicator while the chrome is collapsed into the lone scrub bar.
    let onScrubActiveChange: (Bool) -> Void
    /// True while the pull-to-dismiss drag (and its spring-back) is live. Freezes the
    /// auto-hide: a chrome hide mid-drag collapses the status-bar inset, which would shear
    /// the safe-area-bounded top bar away from the rigidly-translating card. See
    /// `PlayerPullToDismiss`.
    let pullDragging: Bool
    #endif
    /// Reports menu state (track panels / debug sheet) to `PlayerView`: iOS suspends
    /// the pull-to-dismiss gesture while a panel owns the screen; tvOS suspends the
    /// HUD's inactivity auto-hide.
    let onMenuOpenChange: (Bool) -> Void
    #if os(tvOS)
    /// Back pressed with NO menu open: fold the HUD (the reducer's `.menu`). Owned
    /// here — one root `onExitCommand` branches menu-close vs HUD-fold, so Back can
    /// never fold the chrome out from under an open panel no matter where focus sits
    /// (the old deeper-handler-wins split lost whenever first focus missed the panel).
    let onExitHUD: () -> Void
    #endif
    let onDismiss: () -> Void
    #if DEBUG
    /// Preview-only: forces the big (iPad-scale) layout at this width regardless of the
    /// running device, so a `#Preview` can render BOTH HUD variants on one iPhone-sim
    /// destination. `nil` at every production call site (the layout derives from `isPad`).
    var previewBigWidth: CGFloat? = nil
    #endif

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if !os(tvOS)
    /// iPhone orientation, for the rotate button (see `rotateButton`): on iPhone a
    /// `.compact` vertical size class means landscape, `.regular` means portrait.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    @State private var hideTask: Task<Void, Never>? = nil
    @State private var isScrubbing = false
    @State private var scrubProgress: Double = 0
    /// Bumped on every drag start so a slow seek can't clear `isScrubbing` after a newer
    /// drag began (which would snap the thumb back to live playback mid-grab).
    @State private var scrubGeneration = 0
    /// A finger is on the bar (iOS): the chrome collapses into the lone scrub bar over
    /// a dimmed, paused frame — the touch analog of tvOS `PlayerHUDState.swipeScrub`.
    /// Never set on tvOS, where that collapse is reducer-owned in `PlayerView`.
    @State private var dragScrubbing = false
    /// Whether playback was live when the drag began — the commit resumes iff true.
    @State private var scrubWasPlaying = false
    #if os(tvOS)
    /// Whether the scrub bar holds focus — drives the focused-handle ring and gates
    /// remote left/right into ±10s seek steps.
    @FocusState private var scrubberFocused: Bool
    #endif
    /// Which track menu is open. EVERY platform presents it as the INLINE
    /// corner-aligned panel (see `inlineTrackPanel` — the TV-app look: the panel's
    /// bottom-left corner sits exactly where the chip's is and the chip hides, no
    /// popover arrow). Touch dismisses via the tap catcher; tvOS contains focus in
    /// the panel and dismisses on Menu (`onExitCommand`).
    // nonisolated: `chipNearest` (and its tests) hash this off the main actor — the
    // app target's default-MainActor mode would otherwise isolate the conformance.
    nonisolated enum TrackMenuKind: Hashable {
        case audio, subtitles, speed, chapters
        /// VoiceOver name for the open panel. The in-panel `MenuHeader` was removed, so the
        /// panel container carries the menu's name instead — the opening chip is `.disabled`
        /// (hence hidden from VoiceOver) while the panel is up.
        var accessibilityTitle: String {
            switch self {
            case .audio: "Audio"
            case .subtitles: "Subtitles"
            case .speed: "Playback speed"
            case .chapters: "Chapters"
            }
        }
    }
    /// The open panel, IDENTITY AND ALL (`nil` = none). Not a bare kind beside a generation
    /// counter: those two could only ever be written together, and a write that set one
    /// without the other would silently recycle a panel.
    @State private var openMenu: PanelIdentity?
    /// Chip frames in the "hud" coordinate space — the inline panel's anchors.
    @State private var chipFrames: [TrackMenuKind: CGRect] = [:]
    /// Measured content height PER MENU KIND; the inline panel sizes to it. Keyed
    /// because one shared scalar carried the previous menu's height into the next
    /// menu's first frames (audio's tall list sized the short speed panel, which
    /// then snapped down a frame later).
    @State private var panelContentHeights: [TrackMenuKind: CGFloat] = [:]
    /// The HUD's size in the "hud" coordinate space — the panel's clamp + scale
    /// anchor inputs.
    @State private var hudSize: CGSize = .zero
    #if !os(tvOS)
    /// The live double-tap seek flash (dome + chevrons + "N seconds"); nil when idle.
    @State private var seekFlash: SeekFlash?
    /// Folds a double-tap burst into ONE engine seek after the taps settle — per-tap
    /// seeks thrash a transcode and wedge the player (the tvOS click-seek lesson). Shared
    /// with the tvOS click-seek (`PlayerView`) via `SeekCommitCoalescer`.
    @State private var seekCoalescer = SeekCommitCoalescer()
    @State private var seekFlashDismissTask: Task<Void, Never>?
    /// The drag-scrub (and a11y-adjust) commit in flight. Stored — not an anonymous
    /// `Task` — so `onDisappear` can cancel it: a player dismissed mid-commit would
    /// otherwise still `seek` + `play` the captured engine after teardown (the
    /// generation guard can't help; dismissal never bumps it).
    @State private var scrubCommitTask: Task<Void, Never>?

    private struct SeekFlash {
        var direction: PlayerSeekFlash.Direction
        var seconds: Int
        var tapPoint: CGPoint
        var trigger: Int
        /// Absolute seek target as a 0...1 fraction — drives the shared `PlayerScrubBar`
        /// riding the dome, so its head sits where the accumulated burst will land.
        var targetFraction: Double
        /// Burst clock for the bar's fade — mirrors the dome's internal clock so the bar
        /// fades on the IDENTICAL `PlayerSeekFlash.envelope`. `burstStart` resets on a
        /// direction reversal (the dome remounts via `.id`); `lastTap` bumps every tap.
        var burstStart: Date
        var lastTap: Date
    }
    /// Timestamp + zone of the previous tap — the manual double-tap pairing in
    /// `handleTap` that replaced the count:2 recognizer.
    @State private var lastTap: (date: Date, zone: PlayerSeekFlash.Direction?)? = nil
    /// The status-bar inset, LATCHED while the bar is expected visible: the top bar
    /// pins itself full-bleed and pads by this, so hiding the status bar with the
    /// chrome can't reflow it mid-fade (the show/hide travel was asymmetric — hide
    /// drifted an extra status-bar height). The gate is `statusBarExpectedVisible`,
    /// NOT `inset > 0`: the upward-only ratchet rejected the legitimate 0 of iPhone
    /// landscape, leaving a stale ~59pt portrait inset pushing the bar down for the
    /// whole landscape session (see `TopInsetLatch`).
    @State private var hudTopInset: CGFloat = 0
    /// The PHYSICAL window's larger dimension — the iPad metrics base. The layout
    /// reader is safe-area-bounded and its HEIGHT tracks the status bar, so deriving
    /// u from it re-sized the whole HUD mid-fade whenever the bar hid (scrub entry,
    /// chrome hide): the top bar sank, the scrub bar shrank — portrait only, because
    /// landscape's max dimension is the width, which the status bar never touches.
    @State private var hudPhysicalMax: CGFloat = 0
    /// Physical-bounds orientation, from the same full-bleed probe — feeds
    /// `TopInsetLatch` rule 3 (the safe-bounded reader's w>h flips spuriously
    /// when the status bar toggles in a near-square Stage Manager window).
    @State private var hudPhysicalIsLandscape = false
    #endif

    // debugHUD needs no build-config fork: the binding is unconditional (only the
    // DEBUG-only chip can ever set it), so in Release it's just always false.
    private var menuOpen: Bool { openMenu != nil || debugHUD }

    #if os(tvOS)
    /// The open panel's row focus, keyed by each row's `rowID` (threaded to the rows
    /// via `trackMenuRowFocus` in the environment). Driven PROGRAMMATICALLY on panel
    /// open so first focus lands on the SELECTED row like the system menus —
    /// `prefersDefaultFocus` never applied here (it only matters when nothing has
    /// focus, and opening a panel relocates focus from the just-disabled chip).
    @FocusState private var menuRowFocus: TrackMenuRowID?
    /// The scrubber's frame in the "hud" space — the playhead-dot x for `playheadChip`.
    @State private var scrubberFrame: CGRect = .zero
    #endif
    /// Which track chip holds focus (tvOS; inert on touch — bound via `tvFocused`).
    /// Written when a panel closes (focus returns to the chip that opened it — Back
    /// must peel one layer, not strand focus) and by the chip row's `defaultFocus`
    /// (focus moving down from the scrubber lands on the chip nearest the playhead,
    /// not the geometric screen-center pick).
    @FocusState private var chipFocus: TrackMenuKind?
    /// False while the stream is still resolving/buffering. The chrome mounts from
    /// loading onward so Close, tap-to-toggle, and the track chips work immediately;
    /// engine-backed transport (play/pause, skip, chapter seek, double-tap seek)
    /// gates on this — the centre cluster is hidden outright because the loading
    /// scrim's ring owns that spot.
    private var playbackReady: Bool { vm.phase == .playing }
    /// Centre transport visibility. Absent until the stream plays and while a stall
    /// scrim is up — the scrim's ring occupies the transport's exact spot (loading and
    /// rebuffer alike).
    private var showsCenterTransport: Bool {
        guard playbackReady, !vm.showsStallScrim else { return false }
        #if os(tvOS)
        // tvOS: nudging the focused scrubber with L/R keeps the FULL chrome up, so the
        // transport must not blink out under it — and a vertical focus move past it must
        // never hide it (that latched `isScrubbing` and stranded the focus engine on a
        // disappearing cluster). Only the loading/stall ring claims this spot here.
        return true
        #else
        // iOS drag-scrub collapses the chrome to the lone bar; hold the transport out
        // while the commit is in flight (`isScrubbing` outlives the finger) so the
        // paused-state glyph can't flash before the seek's `.buffering` scrim lands.
        return !isScrubbing
        #endif
    }
    /// Deliberately device-based, not `@Environment(\.appIdiom)` (which is size-class
    /// derived): the phone layout must apply to ALL iPhones, including a regular-width
    /// Pro Max in landscape that reports `.regular` — keying on size class would push it
    /// into the scaled big layout. The big layout's `GeometryReader` already adapts to a
    /// narrowed iPad window, so device idiom is the right axis here.
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    #if !os(tvOS)
    /// The in-view mirror of `PlayerView`'s status-bar rule (`!chromeVisible ||
    /// scrubHUDActive` hides it): while this is true, the safe-area reader reports
    /// the status bar's REAL inset — including a legitimate 0 in iPhone landscape —
    /// and `TopInsetLatch` may adopt it. While false, the bar is hidden by us and
    /// its transient 0 must be ignored.
    private var statusBarExpectedVisible: Bool { controlsVisible && !dragScrubbing }
    #endif

    /// Directional reveal offset for a chrome section (see `PlayerMetrics.hudSlide`):
    /// the section parks at `distance` while hidden and rides the same retargetable
    /// 0.15s curve as the fade, so a mid-animation tap reverses position and opacity
    /// together. Zero under Reduce Motion (crossfade only) — and always zero on
    /// tvOS, where `controlsVisible` is pinned true and the reducer owns visibility.
    private func revealOffset(_ distance: CGFloat) -> CGFloat {
        (controlsVisible || reduceMotion) ? 0 : distance
    }

    var body: some View {
        ZStack {
            #if os(tvOS)
            Color.clear
                .contentShape(.rect)
                .onTapGesture { toggleControls() }
                .ignoresSafeArea()
            #else
            // Tap surface: ONE single-tap recognizer, zero recognition delay — every
            // tap-up toggles the chrome the instant it lands, so a lone edge tap flicks
            // the HUD on·off with no delay. Double-tap seek is paired MANUALLY inside
            // `handleTap` (timestamp + zone): a count:2 recognizer — even composed
            // `simultaneously` — gated the second tap's delivery by ~0.5s on device while
            // it disambiguated, and `.exclusively` before it delayed the first. The pair's
            // second tap hides the chrome and seeks; see `handleTap`.
            GeometryReader { geo in
                ZStack {
                    Color.clear
                        .contentShape(.rect)
                        .gesture(
                            SpatialTapGesture(coordinateSpace: .local)
                                .onEnded { value in handleTap(at: value.location, in: geo.size) }
                        )
                    // Hidden the moment playback drops out (track switch → loading
                    // scrim) instead of lingering its 0.9s tail over the new scrim. The
                    // scrub bar that rides this dome is a SIBLING (`seekScrubBar` below) so
                    // it can sit in the safe area at the HUD scrubber's exact spot — this
                    // full-bleed layer is the dome only. Gated `!controlsVisible` in lockstep
                    // with the bar so the two always show and hide together (handleTap keeps
                    // the chrome down for a live burst, so this is normally always true).
                    if let flash = seekFlash, playbackReady, !controlsVisible {
                        PlayerSeekFlash(
                            direction: flash.direction, seconds: flash.seconds,
                            tapPoint: flash.tapPoint, trigger: flash.trigger,
                            metrics: isPad
                                ? PlayerMetrics(width: max(geo.size.width, geo.size.height))
                                : .phone
                        )
                        // A reversal is a new burst: without the identity key the
                        // reused view keeps the old direction's burst clock, so the
                        // opposite dome would snap in mid-march instead of rising.
                        .id(flash.direction)
                    }
                }
            }
            .ignoresSafeArea()
            #endif

            // Always mounted, opacity-driven: a tap mid-fade RETARGETS the running
            // animation from its current value, so show/hide reverses instantly.
            // The old structural `if` + transition re-inserted the subtree and
            // replayed the whole curve on every quick second tap.
            controls
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)

            #if !os(tvOS)
            // The scrub bar riding the double-tap dome — the SAME `PlayerProgressBar(.scrub)`
            // the tvOS seek shows. A safe-area SIBLING (not inside the full-bleed dome
            // layer), so it pins to the HUD scrubber's EXACT height/width via the shared
            // `scrubberInsetX`/`scrubberBottom`. Faded on the dome's own envelope so it
            // shows/hides WITH the scrim. Gated on `!controlsVisible`: the full-HUD scrubber
            // sits at the IDENTICAL rect, so the two must never render together (a middle
            // tap can raise the HUD mid-burst — this yields the bar to it, no double-exposure).
            if let flash = seekFlash, playbackReady, !controlsVisible {
                seekScrubBar(flash)
            }
            #endif
        }
        .animation(.chromeToggle, value: controlsVisible)
        .animation(.playerStateCrossfade, value: dragScrubbing)
        // The centre transport swaps with the stall scrim's ring — fade, don't pop.
        .animation(.playerStateCrossfade, value: vm.showsStallScrim)
        // …and fades back in when an in-flight scrub commit lands (the transport
        // is held out through `isScrubbing` so the paused glyph can't flash).
        .animation(.playerStateCrossfade, value: isScrubbing)
        #if !os(tvOS)
        .onAppear { scheduleHide() }
        // The sleeping tasks outlive a dismissed player: the seek commit would fire
        // into a mid-teardown engine, the others write to dead @State. Cancel them.
        .onDisappear {
            hideTask?.cancel()
            seekCoalescer.cancel()
            seekFlashDismissTask?.cancel()
            scrubCommitTask?.cancel()
        }
        // A live pull-drag (and its spring-back) suspends the auto-hide — see
        // `pullDragging`. The hide task is already armed when the drag starts, so cancel
        // it on engage and re-arm a fresh timer on release.
        .onChange(of: pullDragging) { _, dragging in
            if dragging { hideTask?.cancel() } else { scheduleHide() }
        }
        #endif
        .onChange(of: menuOpen) { _, open in
            if open { hideTask?.cancel() } else { scheduleHide() }
            onMenuOpenChange(open)
        }
        #if os(tvOS)
        // ONE Back handler for the whole HUD, wherever focus sits: an open panel
        // closes (focus back to its chip); otherwise the HUD folds to the floor.
        .onExitCommand {
            if openMenu != nil { closeMenu() } else { onExitHUD() }
        }
        #endif
        // When the chrome hides, the chips anchoring the inline panels (and the
        // debug sheet's binding) go with it — a stale `openMenu`/`debugHUD` would
        // keep `menuOpen` true and lock the user out of the chrome. Clear them.
        .onChange(of: controlsVisible) { _, visible in
            if !visible { closeAllMenus() }
        }
        // Pause pins the chrome (see `scheduleHide`); resuming re-arms the timer. Keyed on
        // INTENT so it agrees with `scheduleHide`'s own guard: the engine mirror lags a
        // command by up to a poll (seconds on wmv), and a scrub's transient beats move it
        // without the user ever asking for a pause.
        .onChange(of: vm.desiredPlaying) { _, playing in
            if playing {
                if controlsVisible { scheduleHide() }
            } else {
                hideTask?.cancel()
            }
        }
        // The fetch pinned the chrome open (see `scheduleHide`); its landing re-arms the
        // timer, so the row doesn't sit there for the rest of the film.
        .onChange(of: vm.loadingSubtitleTrackID) { _, loading in
            if loading == nil, controlsVisible { scheduleHide() }
        }
    }

    // MARK: - Root layout

    @ViewBuilder
    private var controls: some View {
        ZStack {
            // While a finger scrubs, the gradient scrim gives way to the uniform dim
            // of tvOS swipe-scrub so the lone bar reads clearly over the paused frame.
            if dragScrubbing {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            } else {
                scrim
            }
            Group {
                #if os(tvOS)
                bigControls(.tv)
                #else
                // Both branches latch the status-bar inset while the bar is expected
                // visible — the top bars pin full-bleed and pad by the latched value, so
                // the safe-area collapse when the status bar hides can't reflow them
                // mid-fade (see `TopInsetLatch`).
                #if DEBUG
                if let previewBigWidth {
                    // Preview seam: render the big layout on the iPhone sim (no latch/probe).
                    bigControls(PlayerMetrics(width: previewBigWidth))
                } else {
                    sizeAdaptiveControls
                }
                #else
                sizeAdaptiveControls
                #endif
                #endif
            }
            // The open panel owns the surface: on tvOS, disabling the chrome is the
            // focus containment (disabled views can't take focus, so the engine
            // resolves into the panel and stays there); on touch the catcher below
            // already swallows taps, and disabling also hides the dead chrome from
            // VoiceOver. No style here reads `isEnabled` — visually inert.
            .disabled(openMenu != nil)

            // Track menus present INLINE: a corner-aligned panel over the chrome
            // (the TV-app replace), not a popover/sheet. The catcher and the panel
            // are separate ZStack children so the grow transition rides the panel's
            // own inserted root — anchored at the chip's corner — and fires reliably.
            #if !os(tvOS)
            if openMenu != nil {
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture { closeMenu(); resetHideTimer() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Dismiss menu")
            }
            #endif
            if let panel = openMenu, let chip = chipFrames[panel.kind] {
                inlineTrackPanel(panel.kind, chip: chip)
            }
        }
        .coordinateSpace(name: "hud")
        .onGeometryChange(for: CGSize.self) { $0.size } action: { hudSize = $0 }
        #if !os(tvOS)
        // Physical-bounds probe for `hudPhysicalMax` — full-bleed, so its size
        // ignores the status bar's comings and goings entirely.
        .background {
            GeometryReader { phys in
                Color.clear
                    .onChange(of: phys.size, initial: true) { _, s in
                        hudPhysicalMax = max(s.width, s.height)
                        hudPhysicalIsLandscape = s.width > s.height
                    }
            }
            .ignoresSafeArea()
        }
        #endif
        .animation(reduceMotion ? .easeOut(duration: 0.15)
                                : .spring(duration: 0.35, bounce: 0.15), value: openMenu)
        #if os(tvOS)
        // The raw input adapter that held focus on the floor is unmounted when the HUD
        // appears; claim focus for the scrubber rather than letting the engine pick.
        .defaultFocus($scrubberFocused, true)
        #endif
    }

    #if !os(tvOS)
    /// Big (iPad-scale) vs. phone layout, chosen by device idiom — the production path
    /// `controls` falls into once the (DEBUG-only) `previewBigWidth` preview seam is out
    /// of the picture. Factored out so the seam's `#if DEBUG` branch in `controls` doesn't
    /// have to duplicate this pair of `GeometryReader`s.
    @ViewBuilder
    private var sizeAdaptiveControls: some View {
        if isPad {
            GeometryReader { geo in
                // Metrics derive from the PHYSICAL max dimension (the probe in
                // the background below): one control size across orientations
                // AND across status-bar toggles — see `hudPhysicalMax`. The
                // safe-bounded fallback only covers the first frame.
                bigControls(PlayerMetrics(width: hudPhysicalMax > 0
                                ? hudPhysicalMax
                                : max(geo.size.width, geo.size.height)),
                            topInset: hudTopInset,
                            dragging: pullDragging)
                    .modifier(TopInsetLatch(inset: geo.safeAreaInsets.top,
                                            statusBarVisible: statusBarExpectedVisible,
                                            isLandscape: hudPhysicalIsLandscape,
                                            adoptsLandscapeInset: false,
                                            latched: $hudTopInset))
            }
        } else {
            GeometryReader { geo in
                phoneControls(topInset: hudTopInset,
                              dragging: pullDragging)
                    .modifier(TopInsetLatch(inset: geo.safeAreaInsets.top,
                                            statusBarVisible: statusBarExpectedVisible,
                                            isLandscape: hudPhysicalIsLandscape,
                                            adoptsLandscapeInset: true,
                                            latched: $hudTopInset))
            }
        }
    }
    #endif

    /// A panel's identity: which menu, and WHICH OPEN of it. Kind alone is stable across a
    /// close/reopen, which is exactly the case that has to produce a new view, so every value
    /// mints a fresh `token` — construction IS the generation bump, with no counter a future
    /// caller can forget to advance.
    private struct PanelIdentity: Hashable {
        let kind: TrackMenuKind
        private let token = UUID()

        init(kind: TrackMenuKind) { self.kind = kind }
    }

    /// The TV-app corner-aligned track panel (every platform): the panel's
    /// bottom-left corner sits exactly on the (vacated) chip's bottom-left corner —
    /// replace, not popover, so there's no arrow. When a narrow screen can't fit the
    /// panel rightward, alignment mirrors to the chip's bottom-RIGHT corner so the
    /// corners still meet. The grow/shrink scales out of that corner (a screen-space
    /// `UnitPoint`, like the iOS context-menu bloom); content-sized up to a cap.
    @ViewBuilder
    private func inlineTrackPanel(_ kind: TrackMenuKind, chip: CGRect) -> some View {
        let width = min(panelWidth(kind), max(hudSize.width - 32, 240))
        let fitsTrailing = chip.minX + width + 16 <= hudSize.width
        let x = fitsTrailing ? chip.minX : max(chip.maxX - width, 16)
        let height = panelHeight(kind, anchoredTo: chip)
        // Guard each axis: `hudSize == .zero` misses a one-axis-zero size mid-layout,
        // and dividing by it feeds an Inf/NaN anchor into the scale transition.
        let anchor: UnitPoint = (hudSize.width > 0 && hudSize.height > 0) ? UnitPoint(
            x: (fitsTrailing ? chip.minX : chip.maxX) / hudSize.width,
            y: chip.maxY / hudSize.height
        ) : .bottomLeading
        panelMenu(kind)
            // Keyed per OPEN, not per kind, so every open REPLACES the panel instead of
            // morphing it. Kind alone leaked the outgoing panel — and its scroll offset,
            // mid-flight — into a menu opened during the previous one's 0.35s removal
            // spring; for a same-kind reopen it also handed back a panel that had already
            // seated, so the seat and its `onSeated` first focus never ran again.
            .id(openMenu)
            .frame(width: width)
            .frame(height: height)
            .offset(x: x, y: chip.maxY - height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transition(reduceMotion
                ? .opacity
                : .scale(scale: 0.05, anchor: anchor).combined(with: .opacity))
    }

    /// Panel width per menu kind — the content decides (speed is a column of
    /// numbers, chapters carry timecodes and long names), and tvOS scales up:
    /// the menus ride semantic text styles, which render ~1.5× at 10 feet.
    private func panelWidth(_ kind: TrackMenuKind) -> CGFloat {
        let base: CGFloat
        switch kind {
        case .speed: base = 200
        case .audio, .subtitles: base = 320
        case .chapters: base = 360
        }
        #if os(tvOS)
        return base * 1.5
        #else
        // iPhone panels shrink to match the compact phone chips — a 320pt column ate a
        // third of a landscape phone and dwarfed the chip it grew from. iPad keeps the
        // roomier base. (Rows stay full height for touch targets; only the width tightens.)
        return isPad ? base : base * 0.8
        #endif
    }

    /// Content-sized (measured per kind in `TrackMenuPanel`), capped at a fixed
    /// ceiling and at the room above the chip; a 320 fallback covers each kind's
    /// first open before its measurement lands.
    private func panelHeight(_ kind: TrackMenuKind, anchoredTo chip: CGRect) -> CGFloat {
        let content = panelContentHeights[kind] ?? 320
        #if os(tvOS)
        return min(content, 840, max(chip.maxY - 60, 280))
        #else
        return min(content, 520, max(chip.maxY - 24, 160))
        #endif
    }

    @ViewBuilder
    private func panelMenu(_ kind: TrackMenuKind) -> some View {
        Group {
            switch kind {
            case .audio: audioMenuList
            case .subtitles: subtitleMenuList
            case .speed: speedMenuList
            case .chapters: chapterMenuList
            }
        }
        #if os(tvOS)
        // First focus lands on the SELECTED row: assigned programmatically once the panel
        // has seated (see `panelSeatFocus`) — the chrome's disable relocates focus into the
        // panel, and a declarative preference alone loses that race. That seat resolves
        // against the 320pt placeholder viewport only on a kind's FIRST open per
        // `PlayerControlsView` lifetime, since `panelContentHeights` keeps the measurement
        // after that — but on tvOS the controls unmount with the HUD, so every summon is a
        // first open. `defaultFocus` is the fallback that seeds the panel; observed on
        // device it evaluates on first appearance and never re-targets afterwards, contra
        // the doc, which says `.userInitiated` widens evaluation to "user-driven focus
        // navigation as well as automatic changes". Back is handled at the HUD root.
        .environment(\.trackMenuRowFocus, $menuRowFocus)
        .defaultFocus($menuRowFocus, panelFocusRowID(kind), priority: .userInitiated)
        #endif
    }

    /// The panel's `onSeated` hook: on tvOS, land first focus on the row the panel just
    /// scrolled to — `panelSeatRowID` resolves to this same row there, for every kind.
    /// Nil on touch platforms — no focus engine in the inline panel — which keeps this the
    /// only place the tvOS fork lives.
    private func panelSeatFocus(_ kind: TrackMenuKind) -> (() -> Void)? {
        #if os(tvOS)
        // Never write a nil dismiss into a panel with no focusable row at all (every audio
        // track unsupported): the chrome is disabled and nothing in the panel can take
        // focus, so Back would fire with no focused environment to peel back from.
        { if let id = panelFocusRowID(kind) { menuRowFocus = id } }
        #else
        nil
        #endif
    }

    /// The row a panel's list opens SELECTED-at-top on: the selected track / rate, or the
    /// chapter playing now.
    private func panelLeadingRowID(_ kind: TrackMenuKind) -> TrackMenuRowID? {
        switch kind {
        case .audio:
            AudioTrackMenu.leadingRowID(tracks: vm.availableAudioTracks,
                                        selectedID: vm.selectedAudioTrack?.id)
        case .subtitles:
            SubtitleTrackMenu.leadingRowID(tracks: vm.availableSubtitleTracks,
                                           selectedID: vm.selectedSubtitleTrack?.id)
        case .speed:
            SpeedMenu.leadingRowID(options: speedOptions, selected: Double(vm.playbackRate))
        case .chapters:
            ChapterMenu.leadingRowID(chapters: vm.chapters,
                                     atSeconds: CMTimeGetSeconds(vm.currentPosition))
        }
    }

    /// The row the panel actually seats its scroll on. tvOS seats the row it will FOCUS:
    /// audio's unsupported rows are `.disabled` and unfocusable, so the selected row can
    /// differ from the focus target there, and pinning a row focus can't reach leaves the
    /// engine's reveal pulling the offset off the seat. The other three kinds resolve the
    /// same either way; touch platforms have no focus to reconcile and keep the selected row.
    private func panelSeatRowID(_ kind: TrackMenuKind) -> TrackMenuRowID? {
        #if os(tvOS)
        panelFocusRowID(kind)
        #else
        panelLeadingRowID(kind)
        #endif
    }

    #if os(tvOS)
    /// The row the panel should land first focus on: its leading row, except in audio,
    /// where the unsupported rows are `.disabled` and can't take focus.
    private func panelFocusRowID(_ kind: TrackMenuKind) -> TrackMenuRowID? {
        guard kind == .audio else { return panelLeadingRowID(kind) }
        return AudioTrackMenu.focusableLeadingRowID(tracks: vm.availableAudioTracks,
                                                    selectedID: vm.selectedAudioTrack?.id)
    }
    #endif

    private var scrim: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.5), location: 0),
                .init(color: .black.opacity(0.04), location: 0.24),
                .init(color: .black.opacity(0.04), location: 0.56),
                .init(color: .black.opacity(0.66), location: 1)
            ],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
        // Don't swallow taps: empty video-area taps must reach the toggle layer beneath.
        .allowsHitTesting(false)
    }

    // MARK: - HUD layout (one metric-parameterized set for phone + big)
    //
    // The transport cluster, top bar, and chip row are ONE builder each, parameterized
    // by `PlayerMetrics` — the phone (`.phone`) and big (`PlayerMetrics(width:)`/`​.tv`)
    // layouts differ only in the metric values those `m.*` accessors resolve (iPhone
    // reads its fixed `phone*` statics; big screens the `u`-scaled formulas) and in
    // `#if os(tvOS)` slices (Close placement, `.focusSection()`, chip default-focus).
    // The one genuine phone/iPad divergence — how the centre transport is mounted — is
    // kept at the two thin assembly callers (`bigControls`/`phoneControls`) below.

    @ViewBuilder
    private func bigControls(_ m: PlayerMetrics, topInset: CGFloat = 0, dragging: Bool = false) -> some View {
        // Everything but the progress row vanishes while a finger drag-scrubs, leaving
        // the lone bar over the dim — the same collapse as tvOS swipe-scrub.
        if !dragScrubbing {
            Group {
                topBar(m, topInset: topInset, dragging: dragging)

                // Centre transport — always mounted, visibility via opacity/disable (never
                // an `if` on existence). The prev/next pair is gated by the STABLE
                // `supportsEpisodeNavigation`, so removing a just-pressed, focused button
                // mid-flight can't corrupt the tvOS focus engine (the untracked-press
                // assert); disabling a still-mounted button is safe.
                transportCluster(m)
                    #if os(tvOS)
                    // Sized to the cluster ITSELF, before the full-bleed centering frame:
                    // the focus engine picks the nearest focusable along a straight line, so
                    // a screen-spanning section would distort up/down travel between the
                    // scrubber, chips, and this cluster. One stable unit also stops the
                    // engine dropping focus to the scrubber when the glyph re-renders.
                    .focusSection()
                    #endif
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    // Full-bleed center like the loading veil's ring (which this cluster
                    // swaps with): a safe-area-bounded center shifts when the status bar
                    // hides with the chrome — the buttons crept upward mid-fade.
                    .ignoresSafeArea()
                    .opacity(showsCenterTransport ? 1 : 0)
                    .disabled(!showsCenterTransport)
                    .allowsHitTesting(showsCenterTransport)
                    .animation(.playerStateCrossfade, value: showsCenterTransport)

                chipRow(m)
            }
            .transition(.opacity)
        }

        // Progress — anchored bottom; persists through the drag-scrub collapse. Placement
        // is the shared `scrubberInsetX`/`scrubberBottom` (== `padX`/`progressBottom` on
        // big screens) so the double-tap seek bar can pin to this exact spot.
        scrubber(m)
            .padding(.horizontal, m.scrubberInsetX)
            .padding(.bottom, m.scrubberBottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .offset(y: revealOffset(m.hudSlide))
    }

    @ViewBuilder
    private func phoneControls(topInset: CGFloat, dragging: Bool) -> some View {
        let m = PlayerMetrics.phone
        // Same drag-scrub collapse as the big layout: only the progress row survives.
        if !dragScrubbing {
            Group {
                topBar(m, topInset: topInset, dragging: dragging)

                // Centre transport — iPhone mounts it conditionally (no focus engine to
                // strand), so it pops in/out with `showsCenterTransport` rather than the
                // big layout's opacity fade.
                if showsCenterTransport {
                    transportCluster(m)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        // Full-bleed center to match the loading veil's ring — keeps the
                        // cluster pinned while the chrome's status-bar/home-indicator
                        // toggles reflow safe areas.
                        .ignoresSafeArea()
                }

                chipRow(m)
            }
            .transition(.opacity)
        }

        // Progress — persists through the drag-scrub collapse. Placement is the shared
        // `scrubberInsetX`/`scrubberBottom` (== the phone statics) so the double-tap seek
        // bar can pin to this exact spot.
        scrubber(m)
            .padding(.horizontal, m.scrubberInsetX)
            .padding(.bottom, m.scrubberBottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .offset(y: revealOffset(m.hudSlide))
    }

    // MARK: - Shared HUD builders

    /// Top bar — Close · title · AirPlay/PiP pill (tvOS: title only; Close stays in the
    /// bottom chip row and the pill doesn't exist there).
    @ViewBuilder
    private func topBar(_ m: PlayerMetrics, topInset: CGFloat, dragging: Bool) -> some View {
        HStack(spacing: m.topBarGap) {
            #if !os(tvOS)
            PlayerRoundButton(systemImage: "chevron.down", size: m.closeSize, iconScale: 0.46,
                              accessibilityLabel: "Close") { onDismiss() }
            #endif
            titleText(m)
            Spacer(minLength: m.topBarSpacerMin)
            #if !os(tvOS)
            if vm.isVideoAirPlayAvailable || vm.isPiPAvailable {
                PlayerSplitPill(metrics: m, airPlayAvailable: vm.isVideoAirPlayAvailable,
                                pipAvailable: vm.isPiPAvailable) { resetHideTimer(); vm.startPiP() }
            }
            rotateButton(m)
            #endif
        }
        .padding(.horizontal, m.padX)
        // The top bar must ride the pull-to-dismiss card RIGIDLY yet not twitch when the
        // status bar toggles on auto-hide — which pull opposite ways. `ignoresSafeArea(.top)`
        // + latched inset is twitch-free (window-fixed) but SHEARS under the card offset;
        // safe-area-bounded rides the offset but twitches. So SWITCH on `dragging`: the
        // status bar is FROZEN visible during a drag, so the live inset == the latched inset
        // and the two modes share the exact resting spot — the switch is seamless.
        //   • not dragging → `ignoresSafeArea(.top)` + `topBarTop + latched`  (original)
        //   • dragging     → safe-area-bounded (`edges: []`) + `topBarTop`    (rigid)
        // tvOS keeps the plain safe-area path (no status bar): `dragging` false, `topInset` 0.
        .padding(.top, m.topBarTop + (dragging ? 0 : topInset))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .offset(y: revealOffset(-m.hudSlide))
        #if !os(tvOS)
        .ignoresSafeArea(edges: dragging ? [] : .top)
        #endif
    }

    #if !os(tvOS)
    /// iPhone-only orientation toggle, docked in the top bar beside the AirPlay/PiP pill.
    /// The player follows the device (see `OrientationController`), so this exists to force
    /// the other side when the system rotation lock is on, or the user just wants it — in
    /// portrait it offers landscape, in landscape it offers portrait. NEVER on iPad (its
    /// canvas is orientation-agnostic and never managed), guarded by the same `UIDevice`
    /// idiom check as `isPad`. Icon-only circular glass, sized to row with the split pill.
    @ViewBuilder
    private func rotateButton(_ m: PlayerMetrics) -> some View {
        if !isPad {
            // iPhone `.regular` vertical size class == portrait, so it offers landscape.
            let toLandscape = verticalSizeClass == .regular
            PlayerRoundButton(
                systemImage: toLandscape ? "rectangle.landscape.rotate" : "rectangle.portrait.rotate",
                size: m.splitPillHeight, iconScale: 0.42,
                accessibilityLabel: toLandscape ? "Rotate to Landscape" : "Rotate to Portrait"
            ) {
                resetHideTimer()
                // `.landscapeLeft` = Dynamic Island on the RIGHT (the plist docs name these by
                // the home-button side, camera opposite) — the user's stated grip. A single
                // side, not `.landscape`: under an active rotation lock UIKit has no reliable
                // physical side to prefer, and letting it pick landed the island on the left.
                OrientationController.shared.rotatePlayer(to: toLandscape ? .landscapeLeft : .portrait)
            }
        }
    }
    #endif

    /// Player title. iPhone rides Dynamic Type off a 17pt headline; big screens scale a
    /// fixed size from `u` (a `scaledFont` at 10 feet would swing wildly with the accessibility
    /// setting on a canvas that's already distance-anchored).
    @ViewBuilder
    private func titleText(_ m: PlayerMetrics) -> some View {
        if m.deviceClass == .phone {
            Text(vm.title).scaledFont(17, relativeTo: .headline, weight: .bold)
                .foregroundStyle(.white).lineLimit(1)
        } else {
            Text(vm.title).font(.system(size: m.titleSize, weight: .bold))
                .foregroundStyle(.white).lineLimit(1)
        }
    }

    /// Centre transport cluster — previous episode · play/pause · next episode (the ±10s
    /// skip is gesture-only: iOS double-tap thirds · tvOS scrubber move/pan). Movies
    /// (`!supportsEpisodeNavigation`) show play/pause ALONE; episodic content keeps
    /// prev/next, disabled at the series boundaries so the focus engine skips the dead side.
    @ViewBuilder
    private func transportCluster(_ m: PlayerMetrics) -> some View {
        GlassEffectContainer(spacing: Space.s8) {
            HStack(spacing: m.transportGap) {
                if vm.supportsEpisodeNavigation {
                    PlayerRoundButton(systemImage: "backward.end.fill", size: m.transportSkip, iconScale: 0.42,
                                      isEnabled: vm.previousEpisode != nil,
                                      accessibilityLabel: "Previous episode") { playPrevious() }
                }
                // Intent, not the engine mirror: it flips on the press frame and no beat can
                // move it, so the glyph stops flickering through a scrub commit's transient
                // pause/seek/resume beats without any latch pinning it.
                PlayerRoundButton(systemImage: vm.desiredPlaying ? "pause.fill" : "play.fill", size: m.transportPlay,
                                  iconScale: 0.46,
                                  accessibilityLabel: vm.desiredPlaying ? "Pause" : "Play") { togglePlayPause() }
                if vm.supportsEpisodeNavigation {
                    PlayerRoundButton(systemImage: "forward.end.fill", size: m.transportSkip, iconScale: 0.42,
                                      isEnabled: vm.nextEpisode != nil,
                                      accessibilityLabel: "Next episode") { playNext() }
                }
            }
        }
    }

    /// Control row — chips on the track's left end (tvOS keeps Close leading, see the
    /// header note). NO `GlassEffectContainer`: the container renders member glass in its
    /// own layer and reads markedly glassier than the standalone top-bar buttons (and on
    /// tvOS a focused chip's lift left the container-drawn capsule behind as a ghost).
    @ViewBuilder
    private func chipRow(_ m: PlayerMetrics) -> some View {
        HStack(spacing: m.chipRowGap) {
            #if os(tvOS)
            PlayerRoundButton(systemImage: "chevron.down", size: m.closeSize, iconScale: 0.46,
                              accessibilityLabel: "Close") { onDismiss() }
            chips(m)
            #else
            // Labeled row while it fits (any orientation), icon-only only under real
            // overflow: `ViewThatFits` prefers the first (labeled) candidate and drops to
            // the second (icon-only) when the labeled chips can't fit the width — a narrow
            // portrait phone with the full audio+subtitles+speed+chapters set. Each
            // candidate wraps the loose chips in its own `HStack` so they lay out
            // horizontally inside `ViewThatFits` (which arranges candidates, not their
            // contents).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: m.chipRowGap) { chips(m) }
                HStack(spacing: m.chipRowGap) { chips(m, iconOnly: true) }
            }
            #endif
            Spacer(minLength: 0)
        }
        .padding(.horizontal, m.padX)
        .padding(.bottom, m.controlRowBottom)
        #if os(tvOS)
        // Focus moving DOWN from the full-width scrubber lands on the chip nearest the
        // playhead dot — where the user is already looking — not the engine's geometric
        // pick (the screen-center speed chip). The section makes the row one focus target;
        // `userInitiated` priority makes the preference win user-driven entry too.
        .focusSection()
        .defaultFocus($chipFocus, playheadChip, priority: .userInitiated)
        // A chip gaining/losing focus is HUD navigation — re-arm the auto-hide (these moves
        // never reach `send`, and directional clicks don't reliably hit the window press
        // sentinel that feeds the timer otherwise).
        .onChange(of: chipFocus) { _, _ in onActivity() }
        #endif
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .offset(y: revealOffset(m.hudSlide))
    }

    // MARK: - Chips (shared)

    /// The chip has handed its spot to the open inline panel (see
    /// `PlayerGlassChip.isVacated`).
    private func isVacated(_ kind: TrackMenuKind) -> Bool {
        openMenu?.kind == kind
    }

    /// Pure playhead-nearest pick over the measured chip frames — `playheadChip`'s
    /// core, extracted nonisolated so `PlayerControlsViewTests` can pin the mapping.
    nonisolated static func chipNearest(
        playheadX: CGFloat, in frames: [TrackMenuKind: CGRect]
    ) -> TrackMenuKind? {
        frames.min { abs($0.value.midX - playheadX) < abs($1.value.midX - playheadX) }?.key
    }

    /// Live playback position as a clamped 0...1 fraction — shared by the scrubber's
    /// display math and `playheadChip` so the clamp can't drift between them.
    private var liveProgressFraction: Double {
        guard vm.hasKnownDuration else { return 0 }   // canonical "is the runtime usable?" predicate
        return min(max(CMTimeGetSeconds(vm.currentPosition) / CMTimeGetSeconds(vm.currentDuration), 0), 1)
    }

    #if os(tvOS)
    /// Whether a chip can take focus right now. Chapters is the one chip that can be
    /// DISABLED (it gates on a live engine), and a FocusState write or default-focus
    /// preference targeting a disabled view is silently dropped — both the playhead
    /// pick and the close-restore must route around it.
    private func chipIsFocusable(_ kind: TrackMenuKind) -> Bool {
        kind != .chapters || playbackReady
    }

    /// The chip whose center sits nearest the playhead dot — the `defaultFocus`
    /// target when focus moves down from the scrubber. Falls back to the speed chip
    /// (always present and enabled) before geometry lands.
    private var playheadChip: TrackMenuKind {
        let progress = isScrubbing ? scrubProgress : liveProgressFraction
        let candidates = chipFrames.filter { chipIsFocusable($0.key) }
        guard scrubberFrame.width > 0, !candidates.isEmpty else { return .speed }
        let x = scrubberFrame.minX + progress * scrubberFrame.width
        return Self.chipNearest(playheadX: x, in: candidates) ?? .speed
    }
    #endif

    /// Chips appear only once playback is ready, as a COMPLETE set — never one-by-one
    /// as their lists populate. Audio/subtitle/chapter lists arrive at different beats
    /// during a load (and reset on an episode switch), and rendering them as they land
    /// inserted chips at the leading edge and shoved the rest right (the "chips jump"
    /// bug). By `.playing` every list is settled, so the row lays out once in its final
    /// shape. A transcode track switch keeps `phase == .playing`, so the chips never
    /// flicker there — only a true (re)load hides them, which already shows the scrim.
    @ViewBuilder
    private func chips(_ m: PlayerMetrics, iconOnly: Bool = false) -> some View {
        if playbackReady {
            chipSet(m, iconOnly: iconOnly)
        }
    }

    /// `iconOnly` drops each chip's text (iOS overflow fallback; see `chipRow`'s
    /// `ViewThatFits`). Always `false` on tvOS — the TV chip row has room to spare.
    @ViewBuilder
    private func chipSet(_ m: PlayerMetrics, iconOnly: Bool = false) -> some View {
        if !vm.availableAudioTracks.isEmpty {
            PlayerGlassChip(systemImage: "waveform",
                            label: vm.selectedAudioTrack?.displayName ?? "Audio",
                            // Channels promoted onto the chip ("English 7.1"); the codec
                            // stays on the menu detail line (channelLabel strips it).
                            sub: vm.selectedAudioTrack?.channelLabel,
                            isActive: openMenu?.kind == .audio, isVacated: isVacated(.audio), iconOnly: iconOnly, metrics: m,
                            accessibilityLabel: "Audio, \(vm.selectedAudioTrack?.displayName ?? "default")") {
                openPanel(.audio)
            }
            .modifier(TrackChipAnchor(kind: .audio, frames: $chipFrames))
            .tvFocused($chipFocus, equals: .audio)
        }
        if !vm.availableSubtitleTracks.isEmpty {
            // Language promoted to the primary label (the glyph carries the "subtitles"
            // category, Apple-player style); VoiceOver still says "Subtitles, <lang>".
            PlayerGlassChip(systemImage: "captions.bubble",
                            label: vm.selectedSubtitleTrack?.displayName ?? "Off",
                            isActive: openMenu?.kind == .subtitles, isVacated: isVacated(.subtitles), iconOnly: iconOnly,
                            // The pick is applied optimistically, so the label already
                            // names the track being fetched — the chip spins on itself
                            // and stays tappable, so a second pick can cancel the first.
                            isLoading: vm.loadingSubtitleTrackID != nil, metrics: m,
                            accessibilityLabel: "Subtitles, \(vm.selectedSubtitleTrack?.displayName ?? "Off")") {
                openPanel(.subtitles)
            }
            .modifier(TrackChipAnchor(kind: .subtitles, frames: $chipFrames))
            .tvFocused($chipFocus, equals: .subtitles)
        }
        PlayerGlassChip(systemImage: "timer", label: SpeedMenu.label(Double(vm.playbackRate)),
                        isActive: openMenu?.kind == .speed, isVacated: isVacated(.speed), iconOnly: iconOnly, metrics: m,
                        accessibilityLabel: "Playback speed, \(SpeedMenu.label(Double(vm.playbackRate)))") {
            openPanel(.speed)
        }
        .modifier(TrackChipAnchor(kind: .speed, frames: $chipFrames))
        .tvFocused($chipFocus, equals: .speed)
        if !vm.chapters.isEmpty {
            // The whole row only mounts once `playbackReady` (see `chips`), so the
            // engine is live by the time this shows — no mid-load dimming needed.
            PlayerGlassChip(systemImage: "list.bullet", label: "Chapters",
                            isActive: openMenu?.kind == .chapters, isVacated: isVacated(.chapters), iconOnly: iconOnly, metrics: m,
                            accessibilityLabel: "Chapters") {
                openPanel(.chapters)
            }
            .modifier(TrackChipAnchor(kind: .chapters, frames: $chipFrames))
            .tvFocused($chipFocus, equals: .chapters)
        }
        #if DEBUG
        PlayerGlassChip(systemImage: "ladybug", label: "Debug",
                        isActive: debugHUD, iconOnly: iconOnly, metrics: m, accessibilityLabel: "Debug info") {
            resetHideTimer(); debugHUD = true
        }
        .trackPresentation(isPresented: $debugHUD) { debugMenuList }
        #endif
    }

    #if DEBUG
    /// The live debug panel — the one chip still presented as a sheet/popover
    /// (`trackPresentation`); the track menus moved to `inlineTrackPanel`. Brings
    /// its own glass: DebugInfoOverlay owns a ScrollView, so `TrackMenuPanel`'s
    /// outer ScrollView would nest-scroll.
    @ViewBuilder
    private var debugMenuList: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
        DebugInfoOverlay(vm: vm) { debugHUD = false }
            .frame(idealWidth: 440)
            .frame(maxHeight: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .glassEffect(.regular, in: shape)
            .overlay { shape.strokeBorder(.white.opacity(0.12), lineWidth: 1) }
    }
    #endif

    // MARK: - Scrubber (shared visual, platform interaction)

    #if os(tvOS)
    /// tvOS Select on the focused scrubber: commit the pending ±10s scrub head as ONE
    /// engine seek, then drop `isScrubbing` so the bar tracks live playback again — safe
    /// immediately because the VM's `SeekHold` already publishes the target as
    /// `currentPosition` and pins it there until the engine lands.
    /// Generation-guarded so a newer scrub (or a dismissal) can't clear the flag out from
    /// under the live one. `playbackReady` matters beyond the engine-nil case: during a
    /// track-switch re-buffer `currentDuration` is stale-positive (handle() is muted by
    /// isSwitchingTracks), so without it a Select here would fire a real seek at the
    /// mid-reload engine — the transcode seek-wedge class. Same reason on every seek path.
    private func commitScrub(durSeconds: Double) {
        guard playbackReady, vm.engine != nil, durSeconds > 0, isScrubbing else { return }
        let gen = scrubGeneration
        let target = CMTime(seconds: scrubProgress * durSeconds, preferredTimescale: 600)
        // The user's intent, not the engine mirror: `isPlaying` still reads false while the
        // previous seek's beats catch up, and capturing that is what stuck playback on a
        // pause. Routed through `commitScrubSeek` (not a bare `seek`) so an out-of-buffer
        // re-encode transcode's force-resuming re-anchor (#15845) can't un-pause a paused user.
        let resume = vm.desiredPlaying
        Task {
            await vm.commitScrubSeek(to: target, resume: resume)
            if scrubGeneration == gen { isScrubbing = false }
        }
    }
    #endif

    @ViewBuilder
    private func scrubber(_ m: PlayerMetrics) -> some View {
        let durSeconds = CMTimeGetSeconds(vm.currentDuration)
        let liveProgress = liveProgressFraction
        let displayed = isScrubbing ? scrubProgress : liveProgress
        // `displayed * dur` — the SAME clamped value the shared `PlayerProgressBar(scrubbingTo:)`
        // init derives the visible label from (`liveProgress` is already clamped). Used for the
        // VoiceOver value below so it can't diverge from the bar at an out-of-range live
        // position (a beat reporting past-duration would otherwise read past the total in VO).
        let shownSeconds = displayed * durSeconds
        // VoiceOver value for the scrub bar — elapsed of total time (AVPlayerViewController's idiom),
        // not a bare percentage. Shared by both platforms so they announce identically; tracks the
        // scrub head mid-adjust via `shownSeconds`.
        let positionValue = vm.hasKnownDuration
            ? "\(formatPlaybackTime(shownSeconds)) of \(formatPlaybackTime(durSeconds))"
            : ""

        #if os(tvOS)
        // tvOS: a focusable Button wraps the bar. Left/right step a ±10s scrub head
        // (they reach `onMoveCommand` because the bar has no horizontal focusable
        // neighbour); Select commits. The head ring shows only while focused — the bar
        // is its own focus indicator, so the style must paint no system chrome
        // (`.plain` draws the tvOS focus platter around the whole bar).
        Button {
            commitScrub(durSeconds: durSeconds)
        } label: {
            // No bubble on tvOS — the focusable bar is its own indicator.
            PlayerProgressBar(scrubbingTo: displayed, vm: vm, metrics: m,
                              mode: scrubberFocused ? .focused : .normal, showsBubble: false)
        }
        .buttonStyle(TVQuietButtonStyle(pressedOpacity: 0.9))
        // A VoiceOver user landing on the focusable bar otherwise hears no position; announce it.
        .accessibilityLabel("Playback position")
        .accessibilityValue(Text(positionValue))
        .focused($scrubberFocused)
        // The playhead-dot x for `playheadChip` (chip-row default focus) reads off
        // this frame plus the displayed fraction.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("hud")) } action: { scrubberFrame = $0 }
        // Animate the thicken/handle-grow as focus lands, matching the original bar.
        .animation(.easeOut(duration: 0.15), value: scrubberFocused)
        .onMoveCommand { direction in
            guard playbackReady, durSeconds > 0 else { return }
            // ONLY left/right scrub. The bar has no horizontal focus neighbour, so L/R
            // reach here instead of moving focus; up/down ARE focus navigation to the
            // chips / centre transport and must never enter scrub. Latching `isScrubbing`
            // on a vertical press froze the bar at the live fraction and — now that the
            // tvOS centre cluster is visible — hid it out from under the focus engine.
            // So set `isScrubbing` INSIDE the L/R cases, never before the switch.
            let step = 10.0 / durSeconds
            switch direction {
            case .left, .right:
                if !isScrubbing { scrubProgress = liveProgress; isScrubbing = true; scrubGeneration += 1 }
                // Animated so the ±10s step glides and the time digits roll (`.numericText`) —
                // the same curve the bar's head/digit-roll ride (`PlayerScrubBar.scrubSpring`).
                withAnimation(PlayerScrubBar.scrubSpring) {
                    scrubProgress = direction == .left
                        ? max(0, scrubProgress - step)
                        : min(1, scrubProgress + step)
                }
            default:
                break   // up/down: leave focus movement to the engine
            }
        }
        .onChange(of: scrubberFocused) { _, focused in
            onScrubberFocusChange(focused)
            onActivity()   // focus arriving on / leaving the bar is interaction — keep the HUD up
            if !focused && isScrubbing { isScrubbing = false }
        }
        #else
        // A finger on the bar enters drag-scrub: pause on the preview frame, collapse
        // the chrome to the lone bar + bubble (tvOS swipe-scrub's look), then commit
        // ONE seek at finger-up and resume iff playback was live — the same
        // pause → [seek, play] ordering as the tvOS reducer (a per-move seek burst
        // thrashes a transcode and wedges the player).
        // The bubble shows only while the finger's down (`.scrub`); at rest it's the
        // plain `.normal` dot. Same shared readout as the seek bar — only the driver
        // (this DragGesture) and the `.normal`↔`.scrub` morph are this caller's.
        PlayerProgressBar(
            scrubbingTo: displayed, vm: vm, metrics: m,
            mode: dragScrubbing ? .scrub : .normal, showsBubble: dragScrubbing,
            onScrubChanged: { frac in
                // playbackReady: during a track-switch re-buffer the duration is
                // stale-positive — entering a drag then would pause + seek the
                // mid-reload engine (the transcode seek-wedge class).
                guard playbackReady, durSeconds > 0 else { return }
                // Keyed on the FINGER (dragScrubbing), not isScrubbing: the
                // previous commit holds isScrubbing true while its seek is in
                // flight, and a re-drag in that window must still register —
                // bumping the generation so the old commit can neither snap the
                // bar back mid-drag nor resume under the finger.
                if !dragScrubbing {
                    scrubGeneration += 1
                    // The user's transport intent, read fresh on every press. Unlike the
                    // `isPlaying` mirror it isn't moved by the scrub's own pause or by the
                    // engine's lagging beats, so a re-drag during an in-flight commit still
                    // captures "playing", and an explicit pause taken mid-chain
                    // is honored instead of being overridden by a stale chain-start value.
                    scrubWasPlaying = vm.desiredPlaying
                    // The ambient `.animation(value: dragScrubbing)` covers this flip
                    // symmetrically with the release; a grab-side "missing" morph on
                    // device was a Debug-build frame drop (the chrome collapse lands
                    // on the same frame), not an API asymmetry — don't wrap this in
                    // withAnimation again.
                    isScrubbing = true
                    dragScrubbing = true
                    onScrubActiveChange(true)
                    hideTask?.cancel()
                    cancelPendingSeek()
                    Task { await vm.engine?.pause() }
                }
                scrubProgress = frac
            },
            onScrubEnded: { frac in
                dragScrubbing = false
                onScrubActiveChange(false)
                resetHideTimer()
                scrubProgress = frac
                guard playbackReady, vm.engine != nil, durSeconds > 0 else { isScrubbing = false; return }
                let gen = scrubGeneration
                let resume = scrubWasPlaying
                let target = CMTime(seconds: frac * durSeconds, preferredTimescale: 600)
                scrubCommitTask?.cancel()
                scrubCommitTask = Task {
                    // Route through the gated commit seek so an out-of-buffer re-encode
                    // transcode RE-ANCHORS (jellyfin#15845) instead of drifting subtitles;
                    // it also replays `resume`. The glyph needs no protection across this:
                    // it reads `desiredPlaying`, which the drag's engine-level pause never
                    // touched.
                    await vm.commitScrubSeek(to: target, resume: resume)
                    // Release the moment the commit returns — `vm.currentPosition` already
                    // reads the target (the VM's `SeekHold` publishes it at commit time and
                    // pins it there through the reload scrim), so handing the bar back to
                    // live playback can no longer flash the stale pre-seek position.
                    // A newer drag owns the bar now — leave the release to its commit.
                    // Cancellation = the player was dismissed mid-seek (onDisappear):
                    // don't touch a torn-down engine on the way out.
                    guard !Task.isCancelled, scrubGeneration == gen else { return }
                    isScrubbing = false
                }
            }
        )
        // VoiceOver/Switch Control can't drive the drag gesture; expose the bar as an
        // adjustable element so seeking survives the loss of the old UIKit Slider.
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(Text(positionValue))
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityAdjustableAction { direction in
            guard playbackReady, durSeconds > 0 else { return }
            resetHideTimer()
            cancelPendingSeek()
            let step = 10.0 / durSeconds
            let target = direction == .increment ? min(1, displayed + step) : max(0, displayed - step)
            scrubProgress = target
            // Same generation-guarded release as the drag path — otherwise `isScrubbing`
            // sticks true and the bar freezes at `scrubProgress`, never tracking playback.
            if !isScrubbing { isScrubbing = true; scrubGeneration += 1 }
            let gen = scrubGeneration
            guard vm.engine != nil else { isScrubbing = false; return }
            let seekTarget = CMTime(seconds: target * durSeconds, preferredTimescale: 600)
            // The user's intent, not the engine mirror (which lags a previous seek's resume
            // by a poll or a re-buffer). Routed through `commitScrubSeek` (not a bare
            // `seek`) so an out-of-buffer re-encode transcode's force-resuming re-anchor
            // (#15845) can't silently un-pause a paused user.
            let resume = vm.desiredPlaying
            scrubCommitTask?.cancel()
            scrubCommitTask = Task {
                await vm.commitScrubSeek(to: seekTarget, resume: resume)
                // Same generation-guarded, hold-backed release as the drag path.
                guard !Task.isCancelled, scrubGeneration == gen else { return }
                isScrubbing = false
            }
        }
        #endif
    }

    // MARK: - Double-tap seek (touch platforms)

    #if !os(tvOS)
    /// The double-tap PAIRING window: a tap in an outer third within this of a previous
    /// tap in the SAME third is the "second tap" that fires the ±10s step. The standard
    /// iOS double-tap gap (0.3s) — long enough to pair a relaxed double-tap, short enough
    /// that a lone edge tap's chrome toggle reads as instant.
    static let doubleTapWindow: TimeInterval = 0.3

    /// Every tap-up, handled without a count:2 recognizer (which gated the second tap
    /// ~0.5s on device). Manual pairing on `doubleTapWindow`.
    ///
    /// Every tap toggles the chrome the instant it lands — a lone edge tap shows/hides the
    /// HUD with no delay. What makes double-tap-seek coexist with that: the SECOND tap of a
    /// pair doesn't toggle, it HIDES the chrome and starts the seek burst — so the dome +
    /// shared scrub bar take over a clean surface, never fighting a half-shown HUD. (A first
    /// tap that raised the HUD is dropped by that hide; one that lowered it stays lowered.)
    /// While the burst is up, further taps in a third keep stepping (10, 20, 30… — the
    /// YouTube burst) and leave the chrome down. The middle third never seeks; not-ready
    /// playback just toggles.
    private func handleTap(at location: CGPoint, in size: CGSize) {
        let zone = seekZone(at: location, in: size)
        let now = Date()
        // nil = no usable pair: no tap within the window, OR the previous tap was in
        // the middle third (its recorded nil zone flattens out here — a middle tap
        // must never pair with a later outer-third tap as a seek).
        let pairedZone: PlayerSeekFlash.Direction? = lastTap.flatMap { prev in
            now.timeIntervalSince(prev.date) < Self.doubleTapWindow ? prev.zone : nil
        }
        lastTap = (now, zone)

        let durSeconds = CMTimeGetSeconds(vm.currentDuration)

        // A LIVE burst owns the surface — the dome + seek bar are up, chrome down. Route
        // EVERY tap through it: an outer third steps the burst, a middle third is ignored.
        // Crucially nothing here toggles the chrome, so a stray tap can't raise the HUD
        // over the affordance (which would strand the chrome and desync the dome — gated
        // `!controlsVisible` — from the still-marching dome). The burst self-dismisses
        // ~0.9s after the last tap.
        if seekFlash != nil {
            if let zone, playbackReady, durSeconds > 0, size.width > 0 {
                seekStep(zone, at: location, durSeconds: durSeconds, now: now)
            }
            return
        }

        guard let zone, playbackReady, durSeconds > 0, size.width > 0 else {
            toggleControls()   // middle third / not ready — instant toggle, never seeks
            return
        }
        if pairedZone == zone {
            // Second tap of a fresh pair: drop the chrome the first tap may have raised
            // (so the HUD never conflicts with the dome + bar) and start the burst.
            hideControls()
            seekStep(zone, at: location, durSeconds: durSeconds, now: now)
        } else {
            // Lone edge tap: toggle the chrome instantly. A following paired tap will
            // hide it again before the seek.
            toggleControls()
        }
    }

    /// Force the chrome down for a starting seek burst — the dome + scrub bar own the
    /// surface, so a half-shown HUD from the first tap must clear (a plain toggle could
    /// instead SHOW it when the surface was already bare). Mirrors `toggleControls`'
    /// drag-scrub guard: a live drag must keep its bar.
    private func hideControls() {
        guard !dragScrubbing else { return }
        controlsVisible = false   // `onChange(of: controlsVisible)` closes any open menu
    }

    /// Outer thirds are the seek surfaces; the middle third is nil (toggle only).
    private func seekZone(at location: CGPoint, in size: CGSize) -> PlayerSeekFlash.Direction? {
        guard size.width > 0 else { return nil }
        if location.x < size.width / 3 { return .backward }
        if location.x > size.width * 2 / 3 { return .forward }
        return nil
    }

    /// One ±10s step: accumulate the debounced target and drive the flash. The
    /// engine seek is debounced — the whole burst lands as ONE seek.
    private func seekStep(_ direction: PlayerSeekFlash.Direction, at location: CGPoint, durSeconds: Double, now: Date) {
        let delta: Double = direction == .forward ? 10 : -10
        // While a scrub's commit is still in flight the bar's own target is the truth:
        // the finger can have moved past the last committed target, which is all
        // `vm.currentPosition` knows about.
        let livePosition = isScrubbing ? scrubProgress * durSeconds : CMTimeGetSeconds(vm.currentPosition)
        let base = seekCoalescer.pending ?? livePosition
        let target = min(max(base + delta, 0), durSeconds)

        // Same direction = the same burst extends (label accumulates, dome's clock holds);
        // a reversal is a fresh burst (label resets, dome remounts via `.id`, so its
        // `burstStart` must reset too — the bar's fade keys off it).
        let sameDirection = seekFlash?.direction == direction
        let seconds = (sameDirection ? seekFlash?.seconds ?? 0 : 0) + 10
        let burstStart = sameDirection ? (seekFlash?.burstStart ?? now) : now
        seekFlash = SeekFlash(direction: direction, seconds: seconds,
                              tapPoint: location, trigger: (seekFlash?.trigger ?? 0) + 1,
                              targetFraction: durSeconds > 0 ? target / durSeconds : 0,
                              burstStart: burstStart, lastTap: now)
        scheduleSeekCommit(to: target)
        scheduleSeekFlashDismissal()
    }

    /// The scrub bar riding the double-tap dome. Mounted in the body's safe-area context
    /// (a SIBLING of the controls, NOT inside the full-bleed dome), so `PlayerScrubBar`'s
    /// shared `scrubberInsetX`/`scrubberBottom` resolve to the HUD scrubber's exact screen
    /// spot — same height, same width. The bar opacity rides the dome's own
    /// `PlayerSeekFlash.envelope` (keyed off the burst clock) so the two fade as one.
    @ViewBuilder
    private func seekScrubBar(_ flash: SeekFlash) -> some View {
        // iPad metrics ride `hudPhysicalMax` (the physical-bounds probe, populated
        // `initial: true` on appear — always > 0 by the time a seek can run); `PlayerScrubBar`
        // self-pins to the safe-area bottom, so no GeometryReader is needed here.
        let m = isPad ? PlayerMetrics(width: hudPhysicalMax) : .phone
        TimelineView(.animation(paused: reduceMotion)) { context in
            let fade = reduceMotion ? 1.0 : PlayerSeekFlash.envelope(
                sinceBurstStart: context.date.timeIntervalSince(flash.burstStart),
                sinceLastTap: context.date.timeIntervalSince(flash.lastTap))
            PlayerScrubBar(metrics: m, vm: vm, progress: flash.targetFraction)
                .opacity(fade)
        }
        .allowsHitTesting(false)
    }

    /// Accumulate the burst's target into the shared `SeekCommitCoalescer`; it fires ONE
    /// seek after the taps settle (the same fold-a-burst-into-one-seek debounce as the
    /// tvOS click-seek).
    private func scheduleSeekCommit(to target: Double) {
        seekCoalescer.schedule(target) { target in
            // The user's intent, not the engine mirror: this fires 400ms after the last tap,
            // squarely inside the window where a previous seek's resume beat hasn't landed
            // yet. Routed through `commitScrubSeek` (not a bare `seek`) so an out-of-buffer
            // re-encode transcode's force-resuming re-anchor (#15845) can't un-pause a paused user.
            await vm.commitScrubSeek(to: CMTime(seconds: target, preferredTimescale: 600),
                                     resume: vm.desiredPlaying)
        }
    }

    private func scheduleSeekFlashDismissal() {
        seekFlashDismissTask?.cancel()
        seekFlashDismissTask = Task {
            try? await Task.sleep(for: .seconds(PlayerSeekFlash.duration))
            if !Task.isCancelled { seekFlash = nil }
        }
    }

    /// Every OTHER seek-shaped action (drag-scrub, skip button, chapter pick) and a
    /// track reload must drop a queued double-tap burst — its debounced commit
    /// would fire up to 400ms later and drag playback back to the stale target.
    private func cancelPendingSeek() {
        seekCoalescer.cancel()
        seekFlashDismissTask?.cancel()
        seekFlash = nil
    }
    #endif

    // MARK: - Transport actions

    private func togglePlayPause() {
        resetHideTimer()
        // Optimistic + coalescing: vm flips `desiredPlaying` synchronously (glyph and
        // pause-pins-chrome react on the tap frame) and retargets one transport
        // task, so spamming the button only commands the LAST intent.
        vm.togglePlayPause()
    }

    // MARK: - Speed options + track menus

    private let speedOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    /// Every track panel is the same wiring around a different list: the seat row, the
    /// height report and the seat-focus hook all derive from the kind alone. Filled here so
    /// the four builders below carry only their content — and so a fifth menu can't be added
    /// with one of the three quietly missing.
    private func trackMenuPanel(
        _ kind: TrackMenuKind,
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        TrackMenuPanel(
            kind: kind,
            leadingRowID: panelSeatRowID(kind),
            onContentHeightChange: { panelContentHeights[kind] = $0 },
            onSeated: panelSeatFocus(kind),
            content: content
        )
    }

    @ViewBuilder
    private var audioMenuList: some View {
        trackMenuPanel(.audio) {
            AudioTrackMenu(tracks: vm.availableAudioTracks, selectedID: vm.selectedAudioTrack?.id) { track in
                closeMenu(); resetHideTimer()
                #if !os(tvOS)
                cancelPendingSeek()   // a queued burst would seek the mid-reload engine
                #endif
                Task { await vm.selectAudioTrack(track) }
            }
        }
    }

    @ViewBuilder
    private var subtitleMenuList: some View {
        trackMenuPanel(.subtitles) {
            SubtitleTrackMenu(
                tracks: vm.availableSubtitleTracks,
                selectedID: vm.selectedSubtitleTrack?.id,
                loadingID: vm.loadingSubtitleTrackID
            ) { track in
                // Before `closeMenu()`, and before the Task: the row spinner and the
                // chip's both have to be armed on this turn, or the panel is already
                // gone by the time the async pick could arm them.
                vm.armSubtitleFetchIndicator(for: track)
                closeMenu(); resetHideTimer()
                Task { await vm.selectSubtitleTrack(track) }
            }
        }
    }

    @ViewBuilder
    private var chapterMenuList: some View {
        trackMenuPanel(.chapters) {
            ChapterMenu(chapters: vm.chapters) { chapter in
                closeMenu(); resetHideTimer()
                #if !os(tvOS)
                cancelPendingSeek()
                #endif
                Task { await vm.seekToChapter(chapter) }
            }
        }
    }

    @ViewBuilder
    private var speedMenuList: some View {
        trackMenuPanel(.speed) {
            SpeedMenu(options: speedOptions, selected: Double(vm.playbackRate)) { rate in
                closeMenu(); resetHideTimer()
                Task { await vm.setPlaybackRate(Float(rate)) }
            }
        }
    }

    // MARK: - Auto-hide

    private func toggleControls() {
        // A second finger's tap mustn't yank the chrome out from under an active
        // drag-scrub — unmounting the bar kills the gesture with the engine paused.
        guard !dragScrubbing else { return }
        if menuOpen {
            closeAllMenus(); controlsVisible = true; scheduleHide(); return
        }
        controlsVisible.toggle()
        if controlsVisible { scheduleHide() }
    }

    /// Open a track panel: re-arm the auto-hide, then mint a fresh identity for this open
    /// (see `inlineTrackPanel`).
    private func openPanel(_ kind: TrackMenuKind) {
        resetHideTimer()
        openMenu = PanelIdentity(kind: kind)
    }

    /// Close the open track panel, handing focus back to the chip that opened it on
    /// tvOS (row picks and Back alike — focus must never strand in the vacated spot).
    /// The opening chip can be unfocusable by close time (`chipIsFocusable`: a
    /// track-switch re-buffer disables chapters while its panel is up) — fall back
    /// to the speed chip rather than dropping the focus write.
    private func closeMenu() {
        #if os(tvOS)
        if let kind = openMenu?.kind {
            chipFocus = chipIsFocusable(kind) ? kind : .speed
        }
        #endif
        // No `menuRowFocus = nil` here: it would land in the SAME update as the chip claim
        // above with no defined order between them, and a dismiss landing last drops the
        // peel-back to the opening chip onto the playhead-nearest `defaultFocus`. Clearing
        // it is also redundant — `openMenu = nil` takes the panel, and SwiftUI drops a
        // `FocusState` whose focused view is gone.
        openMenu = nil
    }

    private func closeAllMenus() {
        openMenu = nil
        debugHUD = false
    }

    private func resetHideTimer() {
        if !controlsVisible { controlsVisible = true }
        scheduleHide()
    }

    /// Centre-transport episode jumps — one place for the `resetHideTimer` + async hop
    /// the prev/next buttons share across the iPad and phone layouts.
    private func playPrevious() {
        resetHideTimer()
        #if !os(tvOS)
        cancelPendingSeek()   // a queued double-tap burst would seek the NEW episode's engine
        #endif
        Task { await vm.playPreviousEpisode() }
    }
    private func playNext() {
        resetHideTimer()
        #if !os(tvOS)
        cancelPendingSeek()
        #endif
        Task { await vm.playNextEpisode() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        #if os(tvOS)
        return   // Siri Remote has no touch-to-reveal — chrome visibility is reducer-owned.
        #else
        // No auto-hide while a menu is open, a finger holds the bar (hiding
        // mid-drag would unmount the gesture's view and strand the engine paused),
        // or playback is PAUSED — a paused frame with vanishing chrome reads as a
        // dead player. Loading counts as not-playing: the HUD stays over the scrim.
        // Nor while a subtitle is being fetched: the chip's spinner is the ONLY thing
        // reporting that wait, and a cold embedded track takes seconds to extract —
        // hiding the row mid-fetch is how the wait starts reading as a dead pick.
        guard !menuOpen, !dragScrubbing, !pullDragging, vm.desiredPlaying,
              vm.loadingSubtitleTrackID == nil else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { controlsVisible = false }
        }
        #endif
    }
}

// MARK: - Debug overlay presentation

/// The DEBUG chip's presentation (the four track menus are `inlineTrackPanel`
/// on every platform): a focus-driven sheet on tvOS — focusable + scrollable by
/// the remote — a popover on iPad regular, a bottom sheet on iPhone compact,
/// gated so the two touch paths never race.
private struct TrackPresentation<MenuContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    var detents: Set<PresentationDetent> = [.medium, .large]
    @ViewBuilder var menu: () -> MenuContent

    @Environment(\.horizontalSizeClass) private var hSize

    func body(content: Content) -> some View {
        #if os(tvOS)
        content.sheet(isPresented: $isPresented) {
            menu().presentationDetents(detents)
        }
        #else
        content
            .popover(isPresented: gated(whenRegular: true)) {
                menu().preferredColorScheme(.dark).presentationBackground(.clear)
            }
            .sheet(isPresented: gated(whenRegular: false)) {
                menu()
                    .preferredColorScheme(.dark)
                    .presentationDetents(detents)
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.clear)
            }
        #endif
    }

    private func gated(whenRegular: Bool) -> Binding<Bool> {
        Binding(
            get: { isPresented && (hSize == .regular) == whenRegular },
            set: { isPresented = $0 }
        )
    }
}

#if !os(tvOS)
/// Latches the status-bar inset for the full-bleed top bars. Two rules:
/// 1. While the status bar is expected visible, adopt EVERY reported inset —
///    including 0, which is legitimate in iPhone landscape (the old `inset > 0`
///    ratchet rejected it and left a stale ~59pt portrait inset pushing the bar
///    down until the next portrait rotation). Safe-area changes arrive as ONE
///    discrete old→new event per status-bar toggle, so this can reposition at
///    most once — never follow the bar's slide animation.
/// 2. While we hid the bar ourselves (chrome hidden / drag-scrub), keep the last
///    value: the transient collapse to 0 mid-fade is exactly what the latch
///    exists to ignore. There is deliberately NO re-read when visibility flips
///    back on — at that instant the inset still reads the hidden-state 0, and
///    adopting it dropped the top bar a status-bar height during every scrub
///    release (the post-review regression).
/// 3. Rotation TO landscape on iPhone adopts the current inset: a rotation while
///    the bar is hidden produces no inset event (0 → 0), and iPhone landscape's
///    truth is always 0, so this is the one case rule 1 can't reach. iPad skips
///    it — its portrait and landscape insets are equal, so the kept value is
///    already right and adopting a hidden-state 0 would only add a settle.
private struct TopInsetLatch: ViewModifier {
    let inset: CGFloat
    let statusBarVisible: Bool
    /// From the FULL-BLEED physical probe, not the safe-bounded reader — the
    /// safe-bounded height tracks the status bar and can flip w>h spuriously
    /// in near-square Stage Manager windows.
    let isLandscape: Bool
    /// iPhone only (`!isPad`): see rule 3.
    let adoptsLandscapeInset: Bool
    @Binding var latched: CGFloat

    func body(content: Content) -> some View {
        content
            .onChange(of: inset, initial: true) { _, value in
                if statusBarVisible { latched = value }
            }
            .onChange(of: isLandscape) { _, landscape in
                if landscape && adoptsLandscapeInset { latched = inset }
            }
    }
}
#endif

/// Records a track chip's frame in the "hud" space — the inline panel's anchor.
/// (Hiding the open chip is `PlayerGlassChip.isVacated`'s job: opacity alone can't
/// remove glass material, so it has to happen inside the chip.)
private struct TrackChipAnchor: ViewModifier {
    let kind: PlayerControlsView.TrackMenuKind
    @Binding var frames: [PlayerControlsView.TrackMenuKind: CGRect]

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("hud")) } action: { frames[kind] = $0 }
    }
}

private extension View {
    func trackPresentation<MenuContent: View>(
        isPresented: Binding<Bool>,
        detents: Set<PresentationDetent> = [.medium, .large],
        @ViewBuilder menu: @escaping () -> MenuContent
    ) -> some View {
        modifier(TrackPresentation(isPresented: isPresented, detents: detents, menu: menu))
    }
}

#if DEBUG && !os(tvOS)
// Full player chrome over a black frame, in a live `.playing` state — the diagnostic
// asset the HUD-builder dedup is render-verified against (phone statics vs `u`-scaled big
// metrics). The `bigWidth` seam forces the iPad layout on the iPhone sim so both variants
// render on one destination. Non-tvOS only (the tvOS chrome has a different init surface
// and is verified headless).
private struct PlayerControlsPreviewHost: View {
    let bigWidth: CGFloat?
    @State private var vm = PlayerViewModel.previewPlaying()
    @State private var visible = true
    @State private var debugHUD = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerControlsView(
                vm: vm,
                controlsVisible: $visible,
                debugHUD: $debugHUD,
                onScrubActiveChange: { _ in },
                pullDragging: false,
                onMenuOpenChange: { _ in },
                onDismiss: {},
                previewBigWidth: bigWidth
            )
        }
        .environment(\.colorScheme, .dark)
    }
}

#Preview("HUD — phone") { PlayerControlsPreviewHost(bigWidth: nil) }
#Preview("HUD — big (iPad)") { PlayerControlsPreviewHost(bigWidth: 1180) }

// Orientation-v2 render checks (iPhone sim destination). Portrait at the phone's true
// ~393pt width: the labeled audio+subtitles+speed+chapters(+Debug) row can't fit, so
// `chipRow`'s `ViewThatFits` drops to the ICON-ONLY fallback — and the top bar carries the
// iPhone-only rotate control. Landscape (~852pt): the same set fits, so the row stays
// fully LABELED (the `ViewThatFits` primary) with the rotate control still present.
#Preview("HUD — phone portrait (icon-only overflow)", traits: .fixedLayout(width: 393, height: 852)) {
    // `.fixedLayout` canvases don't derive a size class from their aspect, so inject the
    // one the rotate button reads (iPhone portrait == `.regular` → offers landscape).
    PlayerControlsPreviewHost(bigWidth: nil)
        .environment(\.verticalSizeClass, .regular)
}
#Preview("HUD — phone landscape (labeled)", traits: .fixedLayout(width: 852, height: 393)) {
    // iPhone landscape == `.compact` → the rotate button offers portrait.
    PlayerControlsPreviewHost(bigWidth: nil)
        .environment(\.verticalSizeClass, .compact)
}
#endif
