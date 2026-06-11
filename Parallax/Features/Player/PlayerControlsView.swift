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
/// the fixed `.phone` set with bespoke round-button sizes. tvOS drops the centre
/// transport (the remote drives play/pause/skip) and the AirPlay/PiP pill (neither is
/// available on tvOS); iPad puts the AirPlay/PiP split pill in the top bar; iPhone uses
/// a standalone AirPlay button (top) and a PiP button (bottom).
///
/// Controls auto-hide after 3s of inactivity on iOS; tap anywhere to toggle, and
/// double-tap the outer thirds to skip ±10s (the `PlayerSeekFlash` dome is the
/// affordance). tvOS visibility is owned by the HUD reducer in `PlayerView` (this
/// view is mounted only in `.fullHUD`). Auto-hide is suspended while a track menu
/// is open.
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
    #else
    /// Reports drag-scrub activity to `PlayerView`, which hides the status bar and
    /// home indicator while the chrome is collapsed into the lone scrub bar.
    let onScrubActiveChange: (Bool) -> Void
    #endif
    let onDismiss: () -> Void

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
    @State private var audioMenu = false
    @State private var subtitleMenu = false
    @State private var chapterMenu = false
    @State private var speedMenu = false
    #if !os(tvOS)
    /// The live double-tap seek flash (dome + chevrons + "N seconds"); nil when idle.
    @State private var seekFlash: SeekFlash?
    /// Accumulated absolute seek target for the running double-tap burst. Committed
    /// as ONE engine seek after the taps settle — per-tap seeks thrash a transcode
    /// and wedge the player (the tvOS click-seek lesson).
    @State private var pendingSeekTarget: Double?
    @State private var seekCommitTask: Task<Void, Never>?
    @State private var seekFlashDismissTask: Task<Void, Never>?

    private struct SeekFlash {
        var direction: PlayerSeekFlash.Direction
        var seconds: Int
        var tapPoint: CGPoint
        var trigger: Int
    }
    #endif

    // debugHUD needs no build-config fork: the binding is unconditional (only the
    // DEBUG-only chip can ever set it), so in Release it's just always false.
    private var menuOpen: Bool { audioMenu || subtitleMenu || chapterMenu || speedMenu || debugHUD }
    /// False while the stream is still resolving/buffering. The chrome mounts from
    /// loading onward so Close, tap-to-toggle, and the track chips work immediately;
    /// engine-backed transport (play/pause, skip, chapter seek, double-tap seek)
    /// gates on this — the centre cluster is hidden outright because the loading
    /// scrim's ring owns that spot.
    private var playbackReady: Bool { vm.phase == .playing }
    /// Centre transport visibility, shared by the iPad and phone layouts. Absent
    /// until the stream plays and while a stall scrim is up — the scrim's ring
    /// occupies the transport's exact spot (loading and rebuffer alike). Also held
    /// out while a scrub commit is in flight (`isScrubbing` outlives the finger):
    /// the release restores chrome synchronously, but the seek's `.buffering` beat
    /// arrives a few frames later — without the hold the paused-state button
    /// flashes before the scrim replaces it.
    private var showsCenterTransport: Bool { playbackReady && !vm.showsStallScrim && !isScrubbing }
    /// Deliberately device-based, not `@Environment(\.appIdiom)` (which is size-class
    /// derived): the phone layout must apply to ALL iPhones, including a regular-width
    /// Pro Max in landscape that reports `.regular` — keying on size class would push it
    /// into the scaled big layout. The big layout's `GeometryReader` already adapts to a
    /// narrowed iPad window, so device idiom is the right axis here.
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        ZStack {
            #if os(tvOS)
            Color.clear
                .contentShape(.rect)
                .onTapGesture { toggleControls() }
                .ignoresSafeArea()
            #else
            // Tap surface: double-tap on the outer thirds seeks ±10s (the flash is
            // the affordance); a single tap toggles the chrome. Exclusive pairing,
            // so the toggle waits out the double-tap window (the YouTube trade).
            GeometryReader { geo in
                ZStack {
                    Color.clear
                        .contentShape(.rect)
                        .gesture(
                            doubleTapSeek(in: geo.size)
                                .exclusively(before: TapGesture().onEnded { toggleControls() })
                        )
                    // Hidden the moment playback drops out (track switch → loading
                    // scrim) instead of lingering its 0.9s tail over the new scrim.
                    if let flash = seekFlash, playbackReady {
                        PlayerSeekFlash(
                            direction: flash.direction, seconds: flash.seconds,
                            tapPoint: flash.tapPoint, trigger: flash.trigger,
                            metrics: isPad ? PlayerMetrics(width: geo.size.width) : .phone
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

            if controlsVisible {
                controls.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
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
        }
        #endif
        .onChange(of: menuOpen) { _, open in
            if open { hideTask?.cancel() } else { scheduleHide() }
        }
        // When the chrome hides, the views anchoring the track popovers/sheets are
        // removed — SwiftUI can strand a presentation's binding at true, which makes
        // `menuOpen` permanently true and locks the user out of the chrome. Clear them.
        .onChange(of: controlsVisible) { _, visible in
            if !visible { closeAllMenus() }
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
            #if os(tvOS)
            bigControls(.tv)
            #else
            if isPad {
                GeometryReader { geo in bigControls(PlayerMetrics(width: geo.size.width)) }
            } else {
                phoneControls
            }
            #endif
        }
        #if os(tvOS)
        // The raw input adapter that held focus on the floor is unmounted when the HUD
        // appears; claim focus for the scrubber rather than letting the engine pick.
        .defaultFocus($scrubberFocused, true)
        #endif
    }

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
    private func bigControls(_ m: PlayerMetrics) -> some View {
        // Everything but the progress row vanishes while a finger drag-scrubs, leaving
        // the lone bar over the dim — the same collapse as tvOS swipe-scrub.
        if !dragScrubbing {
            Group {
                // Top bar — title left; iPad AirPlay/PiP split pill right.
                HStack(alignment: .top) {
                    Text(vm.title)
                        .font(.system(size: m.titleSize, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: m.chipsGap)
                    #if !os(tvOS)
                    if vm.isVideoAirPlayAvailable || vm.isPiPAvailable {
                        PlayerSplitPill(metrics: m, airPlayAvailable: vm.isVideoAirPlayAvailable,
                                        pipAvailable: vm.isPiPAvailable) { resetHideTimer(); vm.startPiP() }
                    }
                    #endif
                }
                .padding(.horizontal, m.padX)
                .padding(.top, m.topBarTop)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                #if !os(tvOS)
                // Centre transport (iPad only — tvOS uses the remote). See
                // `showsCenterTransport` for the visibility contract.
                if showsCenterTransport {
                    GlassEffectContainer(spacing: Space.s8) {
                        HStack(spacing: m.transportGap) {
                            PlayerRoundButton(systemImage: "gobackward.10", size: m.transportSkip, iconScale: 0.48,
                                              glyphOpticalYOffset: PlayerRoundButton.skipGlyphYOffset,
                                              accessibilityLabel: "Skip back 10 seconds") { skip(-10) }
                            PlayerRoundButton(systemImage: vm.isPlaying ? "pause.fill" : "play.fill", size: m.transportPlay,
                                              iconScale: 0.42, primary: true,
                                              accessibilityLabel: vm.isPlaying ? "Pause" : "Play") { togglePlayPause() }
                            PlayerRoundButton(systemImage: "goforward.10", size: m.transportSkip, iconScale: 0.48,
                                              glyphOpticalYOffset: PlayerRoundButton.skipGlyphYOffset,
                                              accessibilityLabel: "Skip forward 10 seconds") { skip(10) }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                #endif

                // Control row — Close + chips (no split pill here; tvOS has none, iPad's is top).
                // Mirrors the progress row's columns so the rows read as one grid: Close is
                // centered in the elapsed-time column, and the first (audio) chip's left edge
                // lands exactly on the track's left end. The `GlassEffectContainer` grouping
                // (Apple's sibling-glass guidance) is iOS-ONLY: the container renders the glass
                // shapes in its own layer, so on tvOS a focused chip's lift (scale transform)
                // left the container-drawn glass/dim capsule behind as an offset ghost. iOS
                // has no focus lift, so the grouping is safe there.
                HStack(spacing: m.progressRowGap) {
                    PlayerRoundButton(systemImage: "chevron.down", size: m.closeSize, iconScale: 0.46,
                                      accessibilityLabel: "Close") { onDismiss() }
                        .frame(width: m.timeLabelWidth)
                    HStack(spacing: m.chipsGap) { chips(m) }
                    Spacer(minLength: 0)
                }
                .tvPlatformGated { row in
                    GlassEffectContainer(spacing: Space.s8) { row }
                }
                .padding(.horizontal, m.padX)
                .padding(.bottom, m.controlRowBottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .transition(.opacity)
        }

        // Progress — anchored bottom; persists through the drag-scrub collapse.
        scrubber(m)
            .padding(.horizontal, m.padX)
            .padding(.bottom, m.progressBottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    // MARK: - Phone layout (iPhone landscape)

    @ViewBuilder
    private var phoneControls: some View {
        let m = PlayerMetrics.phone
        // Same drag-scrub collapse as the big layout: only the progress row survives.
        if !dragScrubbing {
            Group {
                // Top bar — Close · title · AirPlay.
                HStack(spacing: PlayerMetrics.phoneTopBarGap) {
                    PlayerRoundButton(systemImage: "chevron.down", size: 40, iconScale: 0.46,
                                      accessibilityLabel: "Close") { onDismiss() }
                    Text(vm.title).font(.system(size: 17, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    Spacer(minLength: Space.s8)
                    if vm.isVideoAirPlayAvailable {
                        AirPlayRouteButton()
                            .frame(width: 36, height: 36)
                            // Clear over-video glass + dim, same as PlayerRoundButton.
                            .glassEffect(.clear.interactive(), in: Circle())
                            .background(.black.opacity(0.3), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.20), lineWidth: 1))
                    }
                }
                .padding(.horizontal, PlayerMetrics.phonePadX)
                .padding(.top, PlayerMetrics.phoneTopBarTop)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                // Centre transport. See `showsCenterTransport` for the visibility
                // contract.
                if showsCenterTransport {
                    GlassEffectContainer(spacing: Space.s8) {
                        HStack(spacing: PlayerMetrics.phoneTransportGap) {
                            PlayerRoundButton(systemImage: "gobackward.10", size: 52, iconScale: 0.5,
                                              glyphOpticalYOffset: PlayerRoundButton.skipGlyphYOffset,
                                              accessibilityLabel: "Skip back 10 seconds") { skip(-10) }
                            PlayerRoundButton(systemImage: vm.isPlaying ? "pause.fill" : "play.fill", size: 76,
                                              iconScale: 0.42, primary: true,
                                              accessibilityLabel: vm.isPlaying ? "Pause" : "Play") { togglePlayPause() }
                            PlayerRoundButton(systemImage: "goforward.10", size: 52, iconScale: 0.5,
                                              glyphOpticalYOffset: PlayerRoundButton.skipGlyphYOffset,
                                              accessibilityLabel: "Skip forward 10 seconds") { skip(10) }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }

                // Chip row — chips · PiP, in the progress row's columns (same as the big
                // layout): the first chip's left edge lands on the track's left end, and PiP
                // sits centered under the remaining-time column.
                GlassEffectContainer(spacing: Space.s3) {
                    HStack(spacing: PlayerMetrics.phoneChipRowGap) {
                        chips(m)
                        Spacer(minLength: 0)
                        if vm.isPiPAvailable {
                            PlayerRoundButton(systemImage: "pip.enter", size: 37, iconScale: 0.5,
                                              accessibilityLabel: "Picture in Picture") { resetHideTimer(); vm.startPiP() }
                                .frame(width: m.timeLabelWidth)
                        }
                    }
                }
                .padding(.leading, m.timeLabelWidth + m.progressRowGap)
                .padding(.horizontal, PlayerMetrics.phonePadX)
                .padding(.bottom, PlayerMetrics.phoneChipRowBottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .transition(.opacity)
        }

        // Progress — persists through the drag-scrub collapse.
        scrubber(m)
            .padding(.horizontal, PlayerMetrics.phonePadX)
            .padding(.bottom, PlayerMetrics.phoneProgressBottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    // MARK: - Chips (shared)

    @ViewBuilder
    private func chips(_ m: PlayerMetrics) -> some View {
        if !vm.availableAudioTracks.isEmpty {
            PlayerGlassChip(systemImage: "waveform",
                            label: vm.selectedAudioTrack?.displayName ?? "Audio",
                            isActive: audioMenu, metrics: m,
                            accessibilityLabel: "Audio, \(vm.selectedAudioTrack?.displayName ?? "default")") {
                resetHideTimer(); audioMenu = true
            }
            .trackPresentation(isPresented: $audioMenu) { audioMenuList }
        }
        if !vm.availableSubtitleTracks.isEmpty {
            PlayerGlassChip(systemImage: "captions.bubble", label: "Subtitles",
                            sub: vm.selectedSubtitleTrack?.displayName ?? "Off",
                            isActive: subtitleMenu, metrics: m,
                            accessibilityLabel: "Subtitles, \(vm.selectedSubtitleTrack?.displayName ?? "Off")") {
                resetHideTimer(); subtitleMenu = true
            }
            .trackPresentation(isPresented: $subtitleMenu) { subtitleMenuList }
        }
        PlayerGlassChip(systemImage: "timer", label: SpeedMenu.label(Double(vm.playbackRate)),
                        isActive: speedMenu, metrics: m,
                        accessibilityLabel: "Playback speed, \(SpeedMenu.label(Double(vm.playbackRate)))") {
            resetHideTimer(); speedMenu = true
        }
        .trackPresentation(isPresented: $speedMenu, detents: [.medium]) { speedMenuList }
        if !vm.chapters.isEmpty {
            // Chapter seek needs a live engine — a pick mid-load would be silently
            // lost, so the chip dims until playback starts (unlike audio/subtitles,
            // which re-resolve server-side and work during buffering).
            PlayerGlassChip(systemImage: "list.bullet", label: "Chapters",
                            isActive: chapterMenu, metrics: m, accessibilityLabel: "Chapters") {
                resetHideTimer(); chapterMenu = true
            }
            .trackPresentation(isPresented: $chapterMenu) { chapterMenuList }
            .disabled(!playbackReady)
            .opacity(playbackReady ? 1 : 0.45)
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
    /// The live debug panel, presented like the track menus (sheet on tvOS —
    /// focusable + scrollable by the remote — popover on iPad). Brings its own
    /// glass: DebugInfoOverlay owns a ScrollView, so `trackMenuChrome`'s outer
    /// ScrollView would nest-scroll.
    @ViewBuilder
    private var debugMenuList: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
        DebugInfoOverlay(vm: vm) { debugHUD = false }
            .frame(idealWidth: 440)
            .frame(maxHeight: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .glassEffect(.regular, in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
    #endif

    // MARK: - Scrubber (shared visual, platform interaction)

    @ViewBuilder
    private func scrubber(_ m: PlayerMetrics) -> some View {
        let posSeconds = CMTimeGetSeconds(vm.currentPosition)
        let durSeconds = CMTimeGetSeconds(vm.currentDuration)
        let liveProgress = durSeconds > 0 ? min(max(posSeconds / durSeconds, 0), 1) : 0
        let displayed = isScrubbing ? scrubProgress : liveProgress
        let shownSeconds = isScrubbing ? scrubProgress * durSeconds : posSeconds
        let remaining = max(0, durSeconds - shownSeconds)
        let remainingText = remaining > 0 ? "-\(formatPlaybackTime(remaining))" : formatPlaybackTime(durSeconds)

        #if os(tvOS)
        // tvOS: a focusable Button wraps the bar. Left/right step a ±10s scrub head
        // (they reach `onMoveCommand` because the bar has no horizontal focusable
        // neighbour); Select commits. The head ring shows only while focused — the bar
        // is its own focus indicator, so the style must paint no system chrome
        // (`.plain` draws the tvOS focus platter around the whole bar).
        Button {
            // `playbackReady` matters beyond the engine-nil case: during a
            // track-switch re-buffer `currentDuration` is stale-positive (handle()
            // is muted by isSwitchingTracks), so without it a Select here would
            // fire a real seek at the mid-reload engine — the transcode seek-wedge
            // class. Same reason on every seek path below.
            guard playbackReady, let engine = vm.engine, durSeconds > 0, isScrubbing else { return }
            let gen = scrubGeneration
            let target = CMTime(seconds: scrubProgress * durSeconds, preferredTimescale: 600)
            Task {
                await engine.seek(to: target)
                if scrubGeneration == gen { isScrubbing = false }
            }
        } label: {
            PlayerProgressBar(metrics: m, mode: scrubberFocused ? .focused : .normal,
                              played: displayed, buffered: vm.bufferedFraction,
                              elapsed: formatPlaybackTime(shownSeconds), remaining: remainingText,
                              elapsedSeconds: shownSeconds, remainingSeconds: remaining,
                              chapters: vm.chapterFractions)
        }
        .buttonStyle(TVScrubberButtonStyle())
        .focused($scrubberFocused)
        // Animate the thicken/handle-grow as focus lands, matching the original bar.
        .animation(.easeOut(duration: 0.15), value: scrubberFocused)
        .onMoveCommand { direction in
            guard playbackReady, durSeconds > 0 else { return }
            if !isScrubbing { scrubProgress = liveProgress; isScrubbing = true; scrubGeneration += 1 }
            let step = 10.0 / durSeconds
            // Animated so the ±10s step glides and the time digits roll (`.numericText`).
            withAnimation(.snappy(duration: 0.25, extraBounce: 0)) {
                switch direction {
                case .left: scrubProgress = max(0, scrubProgress - step)
                case .right: scrubProgress = min(1, scrubProgress + step)
                default: break
                }
            }
        }
        .onChange(of: scrubberFocused) { _, focused in
            onScrubberFocusChange(focused)
            if !focused && isScrubbing { isScrubbing = false }
        }
        #else
        // A finger on the bar enters drag-scrub: pause on the preview frame, collapse
        // the chrome to the lone bar + bubble (tvOS swipe-scrub's look), then commit
        // ONE seek at finger-up and resume iff playback was live — the same
        // pause → [seek, play] ordering as the tvOS reducer (a per-move seek burst
        // thrashes a transcode and wedges the player).
        PlayerProgressBar(
            metrics: m, mode: dragScrubbing ? .scrub : .normal, played: displayed,
            buffered: vm.bufferedFraction,
            elapsed: formatPlaybackTime(shownSeconds), remaining: remainingText,
            elapsedSeconds: shownSeconds, remainingSeconds: remaining,
            chapters: vm.chapterFractions,
            bubbleTime: dragScrubbing ? formatPlaybackTime(shownSeconds) : nil,
            bubbleChapter: dragScrubbing ? vm.chapterTitle(atSeconds: shownSeconds) : nil,
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
                guard playbackReady, let engine = vm.engine, durSeconds > 0 else { isScrubbing = false; return }
                let gen = scrubGeneration
                let resume = scrubWasPlaying
                let target = CMTime(seconds: frac * durSeconds, preferredTimescale: 600)
                Task {
                    await engine.seek(to: target)
                    // A newer drag owns the bar now — leave the resume to its commit.
                    guard scrubGeneration == gen else { return }
                    if resume { await engine.play() }
                    isScrubbing = false
                }
            }
        )
        // VoiceOver/Switch Control can't drive the drag gesture; expose the bar as an
        // adjustable element so seeking survives the loss of the old UIKit Slider.
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(Text("\(Int(displayed * 100)) percent"))
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
            guard let engine = vm.engine else { isScrubbing = false; return }
            let seekTarget = CMTime(seconds: target * durSeconds, preferredTimescale: 600)
            Task {
                await engine.seek(to: seekTarget)
                if scrubGeneration == gen { isScrubbing = false }
            }
        }
        #endif
    }

    // MARK: - Double-tap seek (touch platforms)

    #if !os(tvOS)
    private func doubleTapSeek(in size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2, coordinateSpace: .local).onEnded { value in
            handleDoubleTap(at: value.location, in: size)
        }
    }

    /// YouTube-style skip: double-taps on the outer thirds accumulate ±10s steps
    /// (10, 20, 30…) and flash the side dome; the middle third is not a seek
    /// surface. The engine seek is debounced — the burst lands as ONE seek.
    private func handleDoubleTap(at location: CGPoint, in size: CGSize) {
        let durSeconds = CMTimeGetSeconds(vm.currentDuration)
        guard playbackReady, durSeconds > 0, size.width > 0 else { return }
        let direction: PlayerSeekFlash.Direction
        if location.x < size.width / 3 { direction = .backward }
        else if location.x > size.width * 2 / 3 { direction = .forward }
        else { return }

        let delta: Double = direction == .forward ? 10 : -10
        // While a scrub's commit is still in flight (`isScrubbing` holds until the
        // engine seek lands), the bar's target is the truth — `vm.currentPosition`
        // only catches up on the next engine beat, so a double-tap right after a
        // drag would accumulate from the pre-scrub position.
        let livePosition = isScrubbing ? scrubProgress * durSeconds : CMTimeGetSeconds(vm.currentPosition)
        let base = pendingSeekTarget ?? livePosition
        pendingSeekTarget = min(max(base + delta, 0), durSeconds)

        // The label accumulates within one direction; reversing starts a fresh count
        // (the pending target still nets both directions out).
        let seconds = (seekFlash?.direction == direction ? seekFlash?.seconds ?? 0 : 0) + 10
        seekFlash = SeekFlash(direction: direction, seconds: seconds,
                              tapPoint: location, trigger: (seekFlash?.trigger ?? 0) + 1)
        scheduleSeekCommit()
        scheduleSeekFlashDismissal()
    }

    /// ~0.45s of quiet after the last double-tap before the accumulated seek fires —
    /// the same fold-a-burst-into-one-seek debounce as the tvOS click-seek.
    private func scheduleSeekCommit() {
        seekCommitTask?.cancel()
        seekCommitTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let target = pendingSeekTarget else { return }
            pendingSeekTarget = nil
            guard let engine = vm.engine else { return }
            await engine.seek(to: CMTime(seconds: target, preferredTimescale: 600))
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

    private func skip(_ seconds: Double) {
        resetHideTimer()
        #if !os(tvOS)
        cancelPendingSeek()
        #endif
        Task {
            guard let engine = vm.engine else { return }
            let posSeconds = CMTimeGetSeconds(vm.currentPosition)
            let target = CMTime(seconds: max(0, posSeconds + seconds), preferredTimescale: 600)
            await engine.seek(to: target)
        }
    }

    private func togglePlayPause() {
        resetHideTimer()
        Task {
            if vm.isPlaying { await vm.engine?.pause() } else { await vm.engine?.play() }
        }
    }

    // MARK: - Speed options + track menus

    private let speedOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    @ViewBuilder
    private var audioMenuList: some View {
        trackMenuChrome {
            AudioTrackMenu(tracks: vm.availableAudioTracks, selectedID: vm.selectedAudioTrack?.id) { track in
                audioMenu = false; resetHideTimer()
                #if !os(tvOS)
                cancelPendingSeek()   // a queued burst would seek the mid-reload engine
                #endif
                Task { await vm.selectAudioTrack(track) }
            }
        }
    }

    @ViewBuilder
    private var subtitleMenuList: some View {
        trackMenuChrome {
            SubtitleTrackMenu(tracks: vm.availableSubtitleTracks, selectedID: vm.selectedSubtitleTrack?.id) { track in
                subtitleMenu = false; resetHideTimer()
                Task { await vm.selectSubtitleTrack(track) }
            }
        }
    }

    @ViewBuilder
    private var chapterMenuList: some View {
        trackMenuChrome {
            ChapterMenu(chapters: vm.chapters) { chapter in
                chapterMenu = false; resetHideTimer()
                #if !os(tvOS)
                cancelPendingSeek()
                #endif
                Task { await vm.seekToChapter(chapter) }
            }
        }
    }

    @ViewBuilder
    private var speedMenuList: some View {
        trackMenuChrome {
            SpeedMenu(options: speedOptions, selected: Double(vm.playbackRate)) { rate in
                speedMenu = false; resetHideTimer()
                Task { await vm.setPlaybackRate(Float(rate)) }
            }
        }
    }

    /// Scrollable Liquid Glass panel (same `.regular` + white hairline as the chips),
    /// dark-pinned so design tokens resolve to the immersive palette.
    @ViewBuilder
    private func trackMenuChrome<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
        ScrollView {
            content().padding(Space.s8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(idealWidth: 360)
        .frame(maxHeight: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
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

    private func closeAllMenus() {
        audioMenu = false; subtitleMenu = false; chapterMenu = false; speedMenu = false
        debugHUD = false
    }

    private func resetHideTimer() {
        if !controlsVisible { controlsVisible = true }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        #if os(tvOS)
        return   // Siri Remote has no touch-to-reveal — chrome visibility is reducer-owned.
        #else
        // No auto-hide while a menu is open or a finger holds the bar — hiding
        // mid-drag would unmount the gesture's view and strand the engine paused.
        guard !menuOpen, !dragScrubbing else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { controlsVisible = false }
        }
        #endif
    }
}

// MARK: - Track menu presentation

/// Presents a track/speed/chapter menu as a popover on iPad (regular width) and a bottom
/// sheet on iPhone (compact width), gated so the two never race.
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

private extension View {
    func trackPresentation<MenuContent: View>(
        isPresented: Binding<Bool>,
        detents: Set<PresentationDetent> = [.medium, .large],
        @ViewBuilder menu: @escaping () -> MenuContent
    ) -> some View {
        modifier(TrackPresentation(isPresented: isPresented, detents: detents, menu: menu))
    }
}
