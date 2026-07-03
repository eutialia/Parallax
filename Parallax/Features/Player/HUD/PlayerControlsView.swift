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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    @State private var openMenu: TrackMenuKind? = nil
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
    /// Accumulated absolute seek target for the running double-tap burst. Committed
    /// as ONE engine seek after the taps settle — per-tap seeks thrash a transcode
    /// and wedge the player (the tvOS click-seek lesson).
    @State private var pendingSeekTarget: Double?
    @State private var seekCommitTask: Task<Void, Never>?
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
    /// The open panel's row focus, keyed by each row's `focusKey` (threaded to the
    /// rows via `trackMenuRowFocus` in the environment). Driven PROGRAMMATICALLY on
    /// panel open so first focus lands on the SELECTED row like the system menus —
    /// `prefersDefaultFocus` never applied here (it only matters when nothing has
    /// focus, and opening a panel relocates focus from the just-disabled chip).
    @FocusState private var menuRowFocus: AnyHashable?
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
        .animation(.easeOut(duration: 0.15), value: controlsVisible)
        .animation(.easeInOut(duration: 0.2), value: dragScrubbing)
        // The centre transport swaps with the stall scrim's ring — fade, don't pop.
        .animation(.easeInOut(duration: 0.2), value: vm.showsStallScrim)
        // …and fades back in when an in-flight scrub commit lands (the transport
        // is held out through `isScrubbing` so the paused glyph can't flash).
        .animation(.easeInOut(duration: 0.2), value: isScrubbing)
        #if !os(tvOS)
        .onAppear { scheduleHide() }
        // The sleeping tasks outlive a dismissed player: the seek commit would fire
        // into a mid-teardown engine, the others write to dead @State. Cancel them.
        .onDisappear {
            hideTask?.cancel()
            seekCommitTask?.cancel()
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
        // Pause pins the chrome (see `scheduleHide`); resuming re-arms the timer.
        // Engine beats flip `isPlaying` async, so the pause path also has to cancel
        // a hide that `resetHideTimer` armed a beat earlier.
        .onChange(of: vm.isPlaying) { _, playing in
            if playing {
                if controlsVisible { scheduleHide() }
            } else {
                hideTask?.cancel()
            }
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
            if let kind = openMenu, let chip = chipFrames[kind] {
                inlineTrackPanel(kind, chip: chip)
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

    /// Content-sized (measured per kind in `trackMenuChrome`), capped at a fixed
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
        // First focus lands on the SELECTED row: assigned programmatically on mount
        // (the chrome's disable relocates focus into the panel, and a declarative
        // preference alone loses that race), with `defaultFocus` re-targeting any
        // later evaluation while the panel is up. Back is handled at the HUD root.
        .environment(\.trackMenuRowFocus, $menuRowFocus)
        .defaultFocus($menuRowFocus, panelDefaultFocusKey(kind), priority: .userInitiated)
        .task { menuRowFocus = panelDefaultFocusKey(kind) }
        #endif
    }

    #if os(tvOS)
    /// The row the panel should land first focus on — each menu owns its key scheme.
    private func panelDefaultFocusKey(_ kind: TrackMenuKind) -> AnyHashable? {
        switch kind {
        case .audio:
            AudioTrackMenu.defaultFocusKey(tracks: vm.availableAudioTracks,
                                           selectedID: vm.selectedAudioTrack?.id)
        case .subtitles:
            SubtitleTrackMenu.defaultFocusKey(tracks: vm.availableSubtitleTracks,
                                              selectedID: vm.selectedSubtitleTrack?.id)
        case .speed:
            SpeedMenu.defaultFocusKey(options: speedOptions, selected: Double(vm.playbackRate))
        case .chapters:
            ChapterMenu.defaultFocusKey(chapters: vm.chapters,
                                        atSeconds: CMTimeGetSeconds(vm.currentPosition))
        }
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

    // MARK: - Big layout (tvOS + iPad)

    @ViewBuilder
    private func bigControls(_ m: PlayerMetrics, topInset: CGFloat = 0, dragging: Bool = false) -> some View {
        // Everything but the progress row vanishes while a finger drag-scrubs, leaving
        // the lone bar over the dim — the same collapse as tvOS swipe-scrub.
        if !dragScrubbing {
            Group {
                // Top bar — Close · title · AirPlay/PiP pill (tvOS: title only; Close
                // stays in its bottom control row and the pill doesn't exist there).
                HStack(spacing: m.chipsGap) {
                    #if !os(tvOS)
                    PlayerRoundButton(systemImage: "chevron.down", size: m.closeSize, iconScale: 0.46,
                                      accessibilityLabel: "Close") { onDismiss() }
                    #endif
                    Text(vm.title)
                        .font(.system(size: m.titleSize, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    #if !os(tvOS)
                    if vm.isVideoAirPlayAvailable || vm.isPiPAvailable {
                        PlayerSplitPill(metrics: m, airPlayAvailable: vm.isVideoAirPlayAvailable,
                                        pipAvailable: vm.isPiPAvailable) { resetHideTimer(); vm.startPiP() }
                    }
                    #endif
                }
                .padding(.horizontal, m.padX)
                // The top bar must ride the pull-to-dismiss card RIGIDLY yet not twitch when
                // the status bar toggles on auto-hide — which pull opposite ways.
                // `ignoresSafeArea(.top)` + latched inset is twitch-free (window-fixed, ignores
                // the live inset) but SHEARS under the card offset (it re-pins to the window);
                // safe-area-bounded rides the offset but twitches (its live inset collapses a
                // frame off from the toggle). So SWITCH on `dragging`: the status bar is FROZEN
                // visible during a drag (see `pullDragging`), so the live inset == the latched
                // inset and the two modes share the exact resting spot — the switch is seamless.
                //   • not dragging → `ignoresSafeArea(.top)` + `topBarTop + latched`  (original)
                //   • dragging     → safe-area-bounded (`edges: []`) + `topBarTop`    (rigid)
                // Same modifier, only its edge set flips — no structural churn. tvOS keeps the
                // plain safe-area path (no status bar): `dragging` defaults false, `topInset` 0.
                .padding(.top, m.topBarTop + (dragging ? 0 : topInset))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .offset(y: revealOffset(-m.hudSlide))
                #if !os(tvOS)
                .ignoresSafeArea(edges: dragging ? [] : .top)
                #endif

                // Centre transport — previous episode · play/pause · next episode (the
                // ±10s skip is gesture-only now: iOS double-tap thirds · tvOS scrubber
                // move/pan). Movies (`!supportsEpisodeNavigation`) show play/pause ALONE;
                // episodic content keeps prev/next, disabled at the series boundaries so
                // the focus engine skips the dead side. See `showsCenterTransport`.
                //
                // The prev/next pair is gated by `supportsEpisodeNavigation`, which is
                // STABLE per session (movie vs episode never flips during an
                // episode→episode swap) — so when present the buttons stay ALWAYS mounted
                // (visibility is opacity/disable, never an `if` on their existence).
                // REMOVING a just-pressed, focused button mid-flight corrupts the tvOS
                // focus engine — the next directional press asserts in
                // `_UIFocusMovementDirectionalPressGestureRecognizer` ("untracked
                // presses"). Disabling a still-mounted button is safe: the press already
                // completed, and the engine just relocates focus.
                GlassEffectContainer(spacing: Space.s8) {
                    HStack(spacing: m.transportGap) {
                        if vm.supportsEpisodeNavigation {
                            PlayerRoundButton(systemImage: "backward.end.fill", size: m.transportSkip, iconScale: 0.42,
                                              isEnabled: vm.previousEpisode != nil,
                                              accessibilityLabel: "Previous episode") { playPrevious() }
                        }
                        PlayerRoundButton(systemImage: vm.isPlaying ? "pause.fill" : "play.fill", size: m.transportPlay,
                                          iconScale: 0.46,
                                          accessibilityLabel: vm.isPlaying ? "Pause" : "Play") { togglePlayPause() }
                        if vm.supportsEpisodeNavigation {
                            PlayerRoundButton(systemImage: "forward.end.fill", size: m.transportSkip, iconScale: 0.42,
                                              isEnabled: vm.nextEpisode != nil,
                                              accessibilityLabel: "Next episode") { playNext() }
                        }
                    }
                }
                #if os(tvOS)
                // Sized to the cluster ITSELF, before the full-bleed centering frame:
                // the focus engine picks the nearest focusable along a straight line, so
                // a screen-spanning section would distort up/down travel between the
                // scrubber, chips, and this cluster (and could even capture focus meant
                // for them). One stable unit also stops the engine dropping focus to the
                // scrubber when the play/pause glyph re-renders.
                .focusSection()
                #endif
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                // Full-bleed center like the loading veil's ring (which this
                // cluster swaps with): a safe-area-bounded center shifts when the
                // status bar hides with the chrome — the buttons crept upward
                // mid-fade. Same fix as the veil's round-2 device finding.
                .ignoresSafeArea()
                .opacity(showsCenterTransport ? 1 : 0)
                .disabled(!showsCenterTransport)
                .allowsHitTesting(showsCenterTransport)
                .animation(.easeInOut(duration: 0.2), value: showsCenterTransport)

                // Control row — chips on the track's left end (tvOS keeps Close leading,
                // see the header note). NO `GlassEffectContainer` here: the container
                // renders member glass in its own layer and reads markedly glassier
                // than the standalone top-bar buttons (and on tvOS a focused chip's
                // lift left the container-drawn capsule behind as a ghost). Standalone
                // chips share the exact material recipe with Close and the pill.
                HStack(spacing: m.chipsGap) {
                    #if os(tvOS)
                    PlayerRoundButton(systemImage: "chevron.down", size: m.closeSize, iconScale: 0.46,
                                      accessibilityLabel: "Close") { onDismiss() }
                    #endif
                    chips(m)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, m.padX)
                .padding(.bottom, m.controlRowBottom)
                #if os(tvOS)
                // Focus moving DOWN from the full-width scrubber lands on the chip
                // nearest the playhead dot — where the user is already looking — not
                // the engine's geometric pick (the screen-center speed chip). The
                // section makes the row one focus target; the `userInitiated`
                // priority makes the preference win user-driven entry too.
                .focusSection()
                .defaultFocus($chipFocus, playheadChip, priority: .userInitiated)
                // A chip gaining/losing focus is HUD navigation — re-arm the auto-hide
                // (these moves never reach `send`, and directional clicks don't reliably
                // hit the window press sentinel that feeds the timer otherwise).
                .onChange(of: chipFocus) { _, _ in onActivity() }
                #endif
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .offset(y: revealOffset(m.hudSlide))
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

    // MARK: - Phone layout (iPhone landscape)

    @ViewBuilder
    private func phoneControls(topInset: CGFloat, dragging: Bool) -> some View {
        let m = PlayerMetrics.phone
        // Same drag-scrub collapse as the big layout: only the progress row survives.
        if !dragScrubbing {
            Group {
                // Top bar — Close · title · AirPlay/PiP pill (the TV-app corner cluster).
                HStack(spacing: PlayerMetrics.phoneTopBarGap) {
                    PlayerRoundButton(systemImage: "chevron.down", size: PlayerMetrics.phoneCloseSize,
                                      iconScale: 0.46, accessibilityLabel: "Close") { onDismiss() }
                    Text(vm.title).scaledFont(17, relativeTo: .headline, weight: .bold).foregroundStyle(.white).lineLimit(1)
                    Spacer(minLength: Space.s8)
                    if vm.isVideoAirPlayAvailable || vm.isPiPAvailable {
                        PlayerSplitPill(metrics: m, airPlayAvailable: vm.isVideoAirPlayAvailable,
                                        pipAvailable: vm.isPiPAvailable) { resetHideTimer(); vm.startPiP() }
                    }
                }
                .padding(.horizontal, PlayerMetrics.phonePadX)
                // Switch the inset mode on `dragging` — see the iPad top bar. (Landscape has no
                // status bar, so this only bites in portrait.)
                .padding(.top, PlayerMetrics.phoneTopBarTop + (dragging ? 0 : topInset))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .offset(y: revealOffset(-m.hudSlide))
                .ignoresSafeArea(edges: dragging ? [] : .top)

                // Centre transport — previous episode · play/pause · next episode
                // (±10s is gesture-only now; see the iPad transport above). See
                // `showsCenterTransport` for the visibility contract.
                if showsCenterTransport {
                    GlassEffectContainer(spacing: Space.s8) {
                        HStack(spacing: PlayerMetrics.phoneTransportGap) {
                            if vm.supportsEpisodeNavigation {
                                PlayerRoundButton(systemImage: "backward.end.fill", size: PlayerMetrics.phoneTransportSkip,
                                                  iconScale: 0.42,
                                                  isEnabled: vm.previousEpisode != nil,
                                                  accessibilityLabel: "Previous episode") { playPrevious() }
                            }
                            PlayerRoundButton(systemImage: vm.isPlaying ? "pause.fill" : "play.fill",
                                              size: PlayerMetrics.phoneTransportPlay,
                                              iconScale: 0.46,
                                              accessibilityLabel: vm.isPlaying ? "Pause" : "Play") { togglePlayPause() }
                            if vm.supportsEpisodeNavigation {
                                PlayerRoundButton(systemImage: "forward.end.fill", size: PlayerMetrics.phoneTransportSkip,
                                                  iconScale: 0.42,
                                                  isEnabled: vm.nextEpisode != nil,
                                                  accessibilityLabel: "Next episode") { playNext() }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    // Full-bleed center to match the loading veil's ring (see the
                    // iPad transport above) — keeps the cluster pinned while the
                    // chrome's status-bar/home-indicator toggles reflow safe areas.
                    .ignoresSafeArea()
                }

                // Chip row — chips alone on the track's left end; the AirPlay/PiP pill
                // moved to the top bar (the TV-app corner cluster). No glass container
                // (see the big layout's control-row note — chrome parity with the top
                // buttons).
                HStack(spacing: PlayerMetrics.phoneChipRowGap) {
                    chips(m)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, PlayerMetrics.phonePadX)
                .padding(.bottom, PlayerMetrics.phoneChipRowBottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .offset(y: revealOffset(m.hudSlide))
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

    // MARK: - Chips (shared)

    /// The chip has handed its spot to the open inline panel (see
    /// `PlayerGlassChip.isVacated`).
    private func isVacated(_ kind: TrackMenuKind) -> Bool {
        openMenu == kind
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
    private func chips(_ m: PlayerMetrics) -> some View {
        if playbackReady {
            chipSet(m)
        }
    }

    @ViewBuilder
    private func chipSet(_ m: PlayerMetrics) -> some View {
        if !vm.availableAudioTracks.isEmpty {
            PlayerGlassChip(systemImage: "waveform",
                            label: vm.selectedAudioTrack?.displayName ?? "Audio",
                            // Channels promoted onto the chip ("English 7.1"); the codec
                            // stays on the menu detail line (channelLabel strips it).
                            sub: vm.selectedAudioTrack?.channelLabel,
                            isActive: openMenu == .audio, isVacated: isVacated(.audio), metrics: m,
                            accessibilityLabel: "Audio, \(vm.selectedAudioTrack?.displayName ?? "default")") {
                resetHideTimer(); openMenu = .audio
            }
            .modifier(TrackChipAnchor(kind: .audio, frames: $chipFrames))
            .tvFocused($chipFocus, equals: .audio)
        }
        if !vm.availableSubtitleTracks.isEmpty {
            // Language promoted to the primary label (the glyph carries the "subtitles"
            // category, Apple-player style); VoiceOver still says "Subtitles, <lang>".
            PlayerGlassChip(systemImage: "captions.bubble",
                            label: vm.selectedSubtitleTrack?.displayName ?? "Off",
                            isActive: openMenu == .subtitles, isVacated: isVacated(.subtitles), metrics: m,
                            accessibilityLabel: "Subtitles, \(vm.selectedSubtitleTrack?.displayName ?? "Off")") {
                resetHideTimer(); openMenu = .subtitles
            }
            .modifier(TrackChipAnchor(kind: .subtitles, frames: $chipFrames))
            .tvFocused($chipFocus, equals: .subtitles)
        }
        PlayerGlassChip(systemImage: "timer", label: SpeedMenu.label(Double(vm.playbackRate)),
                        isActive: openMenu == .speed, isVacated: isVacated(.speed), metrics: m,
                        accessibilityLabel: "Playback speed, \(SpeedMenu.label(Double(vm.playbackRate)))") {
            resetHideTimer(); openMenu = .speed
        }
        .modifier(TrackChipAnchor(kind: .speed, frames: $chipFrames))
        .tvFocused($chipFocus, equals: .speed)
        if !vm.chapters.isEmpty {
            // The whole row only mounts once `playbackReady` (see `chips`), so the
            // engine is live by the time this shows — no mid-load dimming needed.
            PlayerGlassChip(systemImage: "list.bullet", label: "Chapters",
                            isActive: openMenu == .chapters, isVacated: isVacated(.chapters), metrics: m,
                            accessibilityLabel: "Chapters") {
                resetHideTimer(); openMenu = .chapters
            }
            .modifier(TrackChipAnchor(kind: .chapters, frames: $chipFrames))
            .tvFocused($chipFocus, equals: .chapters)
        }
        #if DEBUG
        PlayerGlassChip(systemImage: "ladybug", label: "Debug",
                        isActive: debugHUD, metrics: m, accessibilityLabel: "Debug info") {
            resetHideTimer(); debugHUD = true
        }
        .trackPresentation(isPresented: $debugHUD) { debugMenuList }
        #endif
    }

    #if DEBUG
    /// The live debug panel — the one chip still presented as a sheet/popover
    /// (`trackPresentation`); the track menus moved to `inlineTrackPanel`. Brings
    /// its own glass: DebugInfoOverlay owns a ScrollView, so `trackMenuChrome`'s
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
    /// engine seek, then drop `isScrubbing` so the bar tracks live playback again.
    /// Generation-guarded so a newer scrub (or a dismissal) can't clear the flag out from
    /// under the live one. `playbackReady` matters beyond the engine-nil case: during a
    /// track-switch re-buffer `currentDuration` is stale-positive (handle() is muted by
    /// isSwitchingTracks), so without it a Select here would fire a real seek at the
    /// mid-reload engine — the transcode seek-wedge class. Same reason on every seek path.
    private func commitScrub(durSeconds: Double) {
        guard playbackReady, vm.engine != nil, durSeconds > 0, isScrubbing else { return }
        let gen = scrubGeneration
        let target = CMTime(seconds: scrubProgress * durSeconds, preferredTimescale: 600)
        // tvOS ±10s scrub never pauses the engine (unlike the touch drag), so `vm.isPlaying`
        // read right now IS the pre-seek intent — nothing transient has touched it. Routed
        // through `commitScrubSeek` (not a bare `seek`) so an out-of-buffer re-encode
        // transcode's force-resuming re-anchor (#15845) can't silently un-pause a paused user.
        let resume = vm.isPlaying
        Task {
            await vm.commitScrubSeek(to: target, resume: resume)
            if scrubGeneration == gen { isScrubbing = false }
        }
    }
    #endif

    #if !os(tvOS)
    /// Hold the scrub latch (`isScrubbing`) until the engine's reported position reaches the
    /// committed target, so the displayed fraction (`isScrubbing ? scrubProgress : liveProgress`)
    /// never flips to a STALE pre-seek `liveProgress` for a frame on release — the scrub-release
    /// "jump" (the dot snaps to the old time, then animates back to the let-go point; playback
    /// itself was always correct). The engine publishes the seek's target position immediately
    /// (VLCKitEngine.seek / AVKitEngine) but the VM consumes that beat on a separate task, so
    /// clearing the latch the instant `seek()` returns races that beat; polling the live fraction
    /// converges in ~one beat, and the ~1s cap keeps the bar from ever freezing if none lands.
    /// Generation-guarded so a newer drag owns the release.
    private func releaseScrubLatch(at frac: Double, durSeconds: Double, generation: Int) async {
        guard durSeconds > 0 else { isScrubbing = false; return }
        for _ in 0..<20 {
            if scrubGeneration != generation { return }
            if abs(liveProgressFraction - frac) * durSeconds < 3 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard scrubGeneration == generation, !Task.isCancelled else { return }
        isScrubbing = false
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
                    // Capture resume intent only at the start of a CHAIN: during
                    // an in-flight commit the engine is paused by the scrub
                    // itself, so re-reading vm.isPlaying here would turn a
                    // drag-while-fetching into a stuck pause (manual play to fix).
                    if !isScrubbing { scrubWasPlaying = vm.isPlaying }
                    // Pin the transport glyph to the pre-scrub play state for the whole commit
                    // so the engine's transient pause/seek/resume beats can't flash it. Re-armed
                    // every press; `scrubWasPlaying` (chain-start) is the source of truth.
                    vm.beginScrubLatch(resumePlaying: scrubWasPlaying)
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
                guard playbackReady, vm.engine != nil, durSeconds > 0 else { isScrubbing = false; vm.endScrubLatch(); return }
                let gen = scrubGeneration
                let resume = scrubWasPlaying
                let target = CMTime(seconds: frac * durSeconds, preferredTimescale: 600)
                scrubCommitTask?.cancel()
                scrubCommitTask = Task {
                    // Route through the gated commit seek so an out-of-buffer re-encode
                    // transcode RE-ANCHORS (jellyfin#15845) instead of drifting subtitles;
                    // it also replays `resume` — the scrub latch (armed at drag start) holds
                    // the glyph on "pause" across the commit, and the engine's resume beat
                    // both confirms it and is pinned by the latch until released below.
                    await vm.commitScrubSeek(to: target, resume: resume)
                    // A newer drag owns the bar now — leave the release to its commit.
                    // Cancellation = the player was dismissed mid-seek (onDisappear):
                    // don't touch a torn-down engine on the way out.
                    guard !Task.isCancelled, scrubGeneration == gen else { return }
                    // Keep the bar pinned at the committed target until the engine's live
                    // position catches up, so it never flashes the stale pre-seek frame.
                    await releaseScrubLatch(at: frac, durSeconds: durSeconds, generation: gen)
                    // Commit settled — release the transport latch. Generation-guarded so a newer
                    // drag that took over keeps its own latch (it re-armed it on its first press).
                    if scrubGeneration == gen { vm.endScrubLatch() }
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
            // VoiceOver adjust never pauses the engine, so `vm.isPlaying` read right now IS
            // the pre-seek intent. Routed through `commitScrubSeek` (not a bare `seek`) so an
            // out-of-buffer re-encode transcode's force-resuming re-anchor (#15845) can't
            // silently un-pause a paused user.
            let resume = vm.isPlaying
            scrubCommitTask?.cancel()
            scrubCommitTask = Task {
                await vm.commitScrubSeek(to: seekTarget, resume: resume)
                guard !Task.isCancelled, scrubGeneration == gen else { return }
                // Same settle-then-release as the drag path, so a VoiceOver/Switch-Control
                // adjust never flashes the stale frame either.
                await releaseScrubLatch(at: target, durSeconds: durSeconds, generation: gen)
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
        // While a scrub's commit is still in flight (`isScrubbing` holds until the
        // engine seek lands), the bar's target is the truth — `vm.currentPosition`
        // only catches up on the next engine beat, so a double-tap right after a
        // drag would accumulate from the pre-scrub position.
        let livePosition = isScrubbing ? scrubProgress * durSeconds : CMTimeGetSeconds(vm.currentPosition)
        let base = pendingSeekTarget ?? livePosition
        let target = min(max(base + delta, 0), durSeconds)
        pendingSeekTarget = target

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
        scheduleSeekCommit()
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

    /// ~0.45s of quiet after the last double-tap before the accumulated seek fires —
    /// the same fold-a-burst-into-one-seek debounce as the tvOS click-seek.
    private func scheduleSeekCommit() {
        seekCommitTask?.cancel()
        seekCommitTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let target = pendingSeekTarget else { return }
            pendingSeekTarget = nil
            // The double-tap burst never pauses the engine, so `vm.isPlaying` read now (post
            // debounce, freshest available) IS the pre-seek intent. Routed through
            // `commitScrubSeek` (not a bare `seek`) so an out-of-buffer re-encode transcode's
            // force-resuming re-anchor (#15845) can't silently un-pause a paused user.
            await vm.commitScrubSeek(to: CMTime(seconds: target, preferredTimescale: 600), resume: vm.isPlaying)
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
    /// track reload must flush a queued double-tap burst — its debounced commit
    /// would fire up to 450ms later and drag playback back to the stale target.
    private func cancelPendingSeek() {
        seekCommitTask?.cancel()
        pendingSeekTarget = nil
        seekFlashDismissTask?.cancel()
        seekFlash = nil
    }
    #endif

    // MARK: - Transport actions

    private func togglePlayPause() {
        resetHideTimer()
        // Optimistic + coalescing: vm flips isPlaying synchronously (glyph and
        // pause-pins-chrome react on the tap frame) and retargets one transport
        // task, so spamming the button only commands the LAST intent.
        vm.togglePlayPause()
    }

    // MARK: - Speed options + track menus

    private let speedOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    @ViewBuilder
    private var audioMenuList: some View {
        trackMenuChrome(.audio) {
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
        trackMenuChrome(.subtitles) {
            SubtitleTrackMenu(tracks: vm.availableSubtitleTracks, selectedID: vm.selectedSubtitleTrack?.id) { track in
                closeMenu(); resetHideTimer()
                Task { await vm.selectSubtitleTrack(track) }
            }
        }
    }

    @ViewBuilder
    private var chapterMenuList: some View {
        trackMenuChrome(.chapters) {
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
        trackMenuChrome(.speed) {
            SpeedMenu(options: speedOptions, selected: Double(vm.playbackRate)) { rate in
                closeMenu(); resetHideTimer()
                Task { await vm.setPlaybackRate(Float(rate)) }
            }
        }
    }

    /// Scrollable Liquid Glass panel (same `.regular` + white hairline as the chips),
    /// dark-pinned so design tokens resolve to the immersive palette. The content
    /// measurement feeds the inline panel's content-sized height, keyed per kind;
    /// width and height are the panel's to set (`panelWidth`/`panelHeight`).
    @ViewBuilder
    private func trackMenuChrome<Content: View>(
        _ kind: TrackMenuKind, @ViewBuilder _ content: () -> Content
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
        ScrollView {
            // No in-panel title: the chip that opened this already names the menu. Just the rows,
            // clipped to `shape` (below) so they scroll cleanly under the panel's rounded corners.
            LazyVStack(alignment: .leading, spacing: 2) {
                content()
            }
            .padding(Space.s8)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelContentHeights[kind] = $0 }
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(shape)
        .glassEffect(.regular, in: shape)
        .overlay { shape.strokeBorder(.white.opacity(0.12), lineWidth: 1) }
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        // The in-panel MenuHeader was removed; name the panel container for VoiceOver so the
        // opened menu still announces which list it is (the opening chip is hidden while open).
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind.accessibilityTitle)
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

    /// Close the open track panel, handing focus back to the chip that opened it on
    /// tvOS (row picks and Back alike — focus must never strand in the vacated spot).
    /// The opening chip can be unfocusable by close time (`chipIsFocusable`: a
    /// track-switch re-buffer disables chapters while its panel is up) — fall back
    /// to the speed chip rather than dropping the focus write.
    private func closeMenu() {
        #if os(tvOS)
        if let kind = openMenu {
            chipFocus = chipIsFocusable(kind) ? kind : .speed
        }
        #endif
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
        guard !menuOpen, !dragScrubbing, !pullDragging, vm.isPlaying else { return }
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
