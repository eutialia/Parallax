import SwiftUI
import AVKit
import CoreMedia
import ParallaxPlayback

/// Engine-agnostic player chrome, overlaid on the video host. Reads `PlayerViewModel`
/// state and drives transport, scrubbing, track selection, speed, and aspect-fill.
///
/// The chrome is always white-on-dark (the player surface is an immersive "screening
/// room" over video, regardless of the app's light/dark appearance). It uses explicit
/// `.white` and bare Liquid Glass materials rather than the light/dark color tokens —
/// and because a bare `.glassEffect(.regular)` resolves its frosted tint from the
/// environment's `colorScheme`, `PlayerView` pins the whole surface to `.dark` (see
/// `PlayerView.body`) so the glass stays consistently dark even when the app is in
/// light mode. Track menus reuse the same `.glassEffect(.regular)` as the bottom bar
/// (`trackMenuChrome`), pinned `.dark` via `preferredColorScheme` since a popover/sheet
/// presents in a fresh environment and design tokens read UIKit traits.
///
/// Track chips (audio, subtitles, speed, chapters) show icon-only on iPhone (compact
/// width); iPad keeps icon + label.
///
/// Controls auto-hide after 3s of inactivity; tap anywhere to toggle. The auto-hide
/// is suspended while a track menu (popover/sheet) is open.
struct PlayerControlsView: View {
    @Bindable var vm: PlayerViewModel
    /// Chrome visibility, owned by `PlayerView` so it can also drive the status bar
    /// (hidden when the chrome is) across the whole fullScreenCover.
    @Binding var controlsVisible: Bool
    /// Whether the video is filling the screen (aspect-fill) vs fit. Owned by
    /// `PlayerView` (it owns the host); the expand chip toggles it.
    let isFilled: Bool
    let onToggleFill: () -> Void
    let onDismiss: () -> Void

    @Environment(\.appIdiom) private var idiom

    @State private var hideTask: Task<Void, Never>? = nil
    @State private var isScrubbing = false
    @State private var scrubProgress: Double = 0
    /// Bumped on every drag start. The seek Task captures it and only clears
    /// `isScrubbing` if no newer drag began while its (possibly slow) seek was in
    /// flight — otherwise a rapid re-grab would snap the thumb to live playback.
    @State private var scrubGeneration = 0
    #if os(tvOS)
    /// Whether the scrub bar holds focus. Drives the scrub head's visibility and the bar's
    /// thicken-on-focus, and gates remote left/right into seek steps.
    @FocusState private var scrubberFocused: Bool
    #endif
    @State private var audioMenu = false
    @State private var subtitleMenu = false
    @State private var chapterMenu = false
    @State private var speedMenu = false

    private var menuOpen: Bool { audioMenu || subtitleMenu || chapterMenu || speedMenu }

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }
                .ignoresSafeArea()   // tap-to-show works across the whole screen

            if controlsVisible {
                controls
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        #if !os(tvOS)
        .onAppear { scheduleHide() }
        #endif
        // Resume the auto-hide once every menu closes; keep controls pinned while open.
        .onChange(of: menuOpen) { _, open in
            if open { hideTask?.cancel() } else { scheduleHide() }
        }
        // When the chrome hides, the views anchoring the track popovers/sheets are
        // removed — SwiftUI can strand a presentation's `isPresented` binding at true.
        // A stuck flag makes `menuOpen` permanently true, which `toggleControls` treats
        // as "a menu is open" and refuses to show the chrome, locking the user out
        // (can't reach Close). Clear the flags whenever the chrome hides so they can't
        // strand. See also the self-heal in `toggleControls`.
        .onChange(of: controlsVisible) { _, visible in
            if !visible { closeAllMenus() }
        }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            transport
            Spacer(minLength: 0)
            bottomBar
        }
        .background(
            LinearGradient(
                colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            // Don't swallow taps: empty video-area taps must reach the Color.clear
            // toggle layer beneath so tap-to-hide works. Buttons, the scrubber, and
            // the bottom glass bar still absorb their own taps (so tapping a control
            // bar doesn't hide the chrome).
            .allowsHitTesting(false)
        )
        #if os(tvOS)
        // The Siri Remote's dedicated play/pause button toggles playback no matter which
        // control holds focus (e.g. while the scrub bar is focused).
        .onPlayPauseCommand { togglePlayPause() }
        #endif
    }

    // MARK: - Top bar

    @ViewBuilder
    private var topBar: some View {
        // tvOS sizes the top-bar glass circles up: at 40–46pt they were tiny across a
        // living room. ~64pt matches the system control footprint at 10-foot distance.
        let circleSize: CGFloat = idiom == .tv ? 64 : 46
        let pipSize: CGFloat = idiom == .tv ? 64 : 40
        HStack(alignment: .top, spacing: Space.s14) {
            GlassCircleButton(systemImage: "chevron.down", size: circleSize, iconSize: idiom == .tv ? 28 : 20) { onDismiss() }

            VStack(alignment: .leading, spacing: 2) {
                Text(vm.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let summary = vm.mediaSummary {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .padding(.top, 2)

            Spacer(minLength: Space.s8)

            if vm.isVideoAirPlayAvailable {
                AVRoutePickerViewRepresentable()
                    .frame(width: pipSize, height: pipSize)
                    .glassEffect(.regular, in: Circle())
            }
            if vm.isPiPAvailable {
                GlassCircleButton(systemImage: "pip.enter", size: pipSize, iconSize: idiom == .tv ? 26 : 18) {
                    resetHideTimer()
                    vm.startPiP()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    // MARK: - Center transport

    private var isPlaying: Bool { vm.isPlaying }

    @ViewBuilder
    private var transport: some View {
        HStack(spacing: 48) {
            GlassCircleButton(systemImage: "gobackward.10", size: 62, iconSize: 28) { skip(-10) }

            Button {
                togglePlayPause()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 88, height: 88)
                    .glassEffect(.regular, in: Circle())
                    // .glassEffect paints a material but adds no hit fill; without an
                    // explicit shape only the glyph is tappable and edge taps fall
                    // through to the toggle layer. Make the whole disc hittable.
                    .contentShape(Circle())
            }
            .tvChipButton()

            GlassCircleButton(systemImage: "goforward.10", size: 62, iconSize: 28) { skip(10) }
        }
    }

    private func skip(_ seconds: Double) {
        resetHideTimer()
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
            if isPlaying { await vm.engine?.pause() }
            else { await vm.engine?.play() }
        }
    }

    // MARK: - Bottom control bar

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 14) {
            scrubber
            chipRow
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private var scrubber: some View {
        let posSeconds = CMTimeGetSeconds(vm.currentPosition)
        let durSeconds = CMTimeGetSeconds(vm.currentDuration)
        let liveProgress = durSeconds > 0 ? min(max(posSeconds / durSeconds, 0), 1) : 0
        // While scrubbing, the thumb follows the finger (scrubProgress); otherwise it
        // tracks live playback. Binding the thumb directly to currentPosition made it
        // snap back mid-drag (felt undraggable), and firing a seek on every value
        // change floods an HLS transcode — so seek once, on release.
        let displayed = isScrubbing ? scrubProgress : liveProgress
        let shownSeconds = isScrubbing ? scrubProgress * durSeconds : posSeconds
        let remaining = max(0, durSeconds - shownSeconds)

        HStack(spacing: 14) {
            Text(formatTime(shownSeconds))
                .font((idiom == .tv ? Font.footnote : .subheadline).weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: idiom == .tv ? 104 : 66, alignment: .leading)

            #if os(tvOS)
            // tvOS has no interactive Slider, so the bar is a focusable Button. While focused,
            // the remote's left/right step a scrub head (±10s) — they reach `onMoveCommand`
            // because the bar has no horizontal focusable neighbour (the time labels aren't
            // focusable) — and pressing Select commits the seek. Up/down still move focus to the
            // transport / chip rows. The head shows only while focused (AVPlayerViewController
            // convention); the bar thickens so the focused state reads at 10 feet.
            Button {
                guard let engine = vm.engine, durSeconds > 0, isScrubbing else { return }
                let gen = scrubGeneration
                let target = CMTime(seconds: scrubProgress * durSeconds, preferredTimescale: 600)
                Task {
                    await engine.seek(to: target)
                    // Keep showing the scrubbed head until the seek lands, unless a newer
                    // scrub began meanwhile (same guard the iOS Slider path uses).
                    if scrubGeneration == gen { isScrubbing = false }
                }
            } label: {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25))
                        Capsule().fill(.white)
                            .frame(width: geo.size.width * displayed)
                        if scrubberFocused {
                            Circle().fill(.white)
                                .frame(width: 22, height: 22)
                                .offset(x: geo.size.width * displayed - 11)
                                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                        }
                    }
                }
                .frame(height: scrubberFocused ? 8 : 4)
                .animation(.easeOut(duration: 0.15), value: scrubberFocused)
            }
            .buttonStyle(.plain)
            .focused($scrubberFocused)
            .onMoveCommand { direction in
                guard durSeconds > 0 else { return }
                // Enter scrub mode on the first step, seeding the head from live playback.
                if !isScrubbing {
                    scrubProgress = liveProgress
                    isScrubbing = true
                    scrubGeneration += 1
                }
                let step = 10.0 / durSeconds
                switch direction {
                case .left:  scrubProgress = max(0, scrubProgress - step)
                case .right: scrubProgress = min(1, scrubProgress + step)
                default: break   // up/down → focus engine moves to transport / chips
                }
            }
            .onChange(of: scrubberFocused) { _, focused in
                // Left the bar without committing (Select) — drop the preview so it snaps
                // back to live playback.
                if !focused && isScrubbing { isScrubbing = false }
            }
            #else
            Slider(
                value: Binding(get: { displayed }, set: { scrubProgress = $0 }),
                in: 0...1,
                onEditingChanged: { editing in
                    resetHideTimer()
                    if editing {
                        scrubProgress = liveProgress
                        isScrubbing = true
                        scrubGeneration += 1
                    } else {
                        guard let engine = vm.engine, durSeconds > 0 else {
                            isScrubbing = false
                            return
                        }
                        let gen = scrubGeneration
                        let target = CMTime(seconds: scrubProgress * durSeconds, preferredTimescale: 600)
                        Task {
                            await engine.seek(to: target)
                            // Skip the clear if the user already started another drag
                            // while this (possibly multi-second transcode) seek ran.
                            if scrubGeneration == gen { isScrubbing = false }
                        }
                    }
                }
            )
            .tint(.white)
            #endif

            Text(remaining > 0 ? "-\(formatTime(remaining))" : formatTime(durSeconds))
                .font((idiom == .tv ? Font.footnote : .subheadline).weight(.semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: idiom == .tv ? 104 : 66, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var chipRow: some View {
        // Wider gaps on tvOS so a focused chip's lift doesn't crowd its neighbours.
        HStack(spacing: idiom == .tv ? Space.s22 : 10) {
            if !vm.availableAudioTracks.isEmpty {
                CtlChip(
                    systemImage: "waveform",
                    label: vm.selectedAudioTrack?.displayName ?? "Audio",
                    accessibilityLabel: "Audio, \(vm.selectedAudioTrack?.displayName ?? "default")",
                    isActive: audioMenu
                ) {
                    resetHideTimer()
                    audioMenu = true
                }
                .trackPresentation(isPresented: $audioMenu) { audioMenuList }
            }

            if !vm.availableSubtitleTracks.isEmpty {
                CtlChip(
                    systemImage: "captions.bubble",
                    label: "Subtitles",
                    sub: vm.selectedSubtitleTrack?.displayName ?? "Off",
                    accessibilityLabel: "Subtitles, \(vm.selectedSubtitleTrack?.displayName ?? "Off")",
                    isActive: subtitleMenu
                ) {
                    resetHideTimer()
                    subtitleMenu = true
                }
                .trackPresentation(isPresented: $subtitleMenu) { subtitleMenuList }
            }

            speedChip

            Spacer(minLength: 0)

            if !vm.chapters.isEmpty {
                CtlChip(
                    systemImage: "list.bullet",
                    label: "Chapters",
                    accessibilityLabel: "Chapters",
                    isActive: chapterMenu
                ) {
                    resetHideTimer()
                    chapterMenu = true
                }
                .trackPresentation(isPresented: $chapterMenu) { chapterMenuList }
            }

            GlassCircleButton(
                systemImage: isFilled ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                size: idiom == .tv ? 56 : 36,
                iconSize: idiom == .tv ? 24 : 16
            ) {
                resetHideTimer()
                onToggleFill()
            }
        }
    }

    // MARK: - Speed

    private let speedOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    // Speed is a CtlChip + popover/sheet like audio/subtitles/chapters, so it joins
    // `menuOpen` and the auto-hide suppression covers it uniformly — no more system
    // `Menu` (which emitted the UIContextMenuInteraction warning) and no fragile pin.
    @ViewBuilder
    private var speedChip: some View {
        CtlChip(
            systemImage: "timer",
            label: SpeedMenu.label(Double(vm.playbackRate)),
            accessibilityLabel: "Playback speed, \(SpeedMenu.label(Double(vm.playbackRate)))",
            isActive: speedMenu
        ) {
            resetHideTimer()
            speedMenu = true
        }
        .trackPresentation(isPresented: $speedMenu, detents: [.medium]) { speedMenuList }
    }

    // MARK: - Track menus (popover on iPad, sheet on iPhone)

    @ViewBuilder
    private var audioMenuList: some View {
        trackMenuChrome {
            AudioTrackMenu(
                tracks: vm.availableAudioTracks,
                selectedID: vm.selectedAudioTrack?.id
            ) { track in
                audioMenu = false   // dismiss the popover/sheet on selection
                resetHideTimer()
                Task { await vm.selectAudioTrack(track) }
            }
        }
    }

    @ViewBuilder
    private var subtitleMenuList: some View {
        trackMenuChrome {
            SubtitleTrackMenu(
                tracks: vm.availableSubtitleTracks,
                selectedID: vm.selectedSubtitleTrack?.id
            ) { track in
                subtitleMenu = false   // dismiss the popover/sheet on selection
                resetHideTimer()
                Task { await vm.selectSubtitleTrack(track) }
            }
        }
    }

    @ViewBuilder
    private var chapterMenuList: some View {
        trackMenuChrome {
            ChapterMenu(chapters: vm.chapters) { chapter in
                chapterMenu = false   // dismiss the popover/sheet on selection
                resetHideTimer()
                Task { await vm.seekToChapter(chapter) }
            }
        }
    }

    @ViewBuilder
    private var speedMenuList: some View {
        trackMenuChrome {
            SpeedMenu(options: speedOptions, selected: Double(vm.playbackRate)) { rate in
                speedMenu = false   // dismiss the popover/sheet on selection
                resetHideTimer()
                Task { await vm.setPlaybackRate(Float(rate)) }
            }
        }
    }

    /// Shared presentation wrapper: scrollable Liquid Glass panel (same `.regular`
    /// variant + white hairline as `bottomBar`), dark-pinned so design tokens resolve
    /// to the immersive palette. `preferredColorScheme` is required alongside the
    /// environment override — `Color.label` et al. read UIKit traits, not SwiftUI's
    /// `colorScheme`, so environment alone leaves menus white-ish in Matinee mode.
    @ViewBuilder
    private func trackMenuChrome<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
        ScrollView {
            content()
                .padding(8)
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

    // MARK: - Time

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Auto-hide

    private func toggleControls() {
        // If this tap reached the toggle layer while a menu is *flagged* open, no
        // popover/sheet is actually presented — a live one would have captured the tap.
        // The flag is stale (SwiftUI stranded it when the chrome was removed), so clear
        // it and show the chrome rather than `guard`-returning forever. This guarantees
        // a phantom menu can never lock the user out of the controls.
        if menuOpen {
            closeAllMenus()
            controlsVisible = true
            scheduleHide()
            return
        }
        controlsVisible.toggle()
        if controlsVisible { scheduleHide() }
    }

    /// Resets every track-menu presentation flag. Keeps `menuOpen` from stranding true
    /// when the chrome is removed out from under a popover/sheet.
    private func closeAllMenus() {
        audioMenu = false
        subtitleMenu = false
        chapterMenu = false
        speedMenu = false
    }

    private func resetHideTimer() {
        if !controlsVisible { controlsVisible = true }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        #if os(tvOS)
        // Siri Remote has no touch-to-reveal — keep chrome visible.
        return
        #else
        // Don't start the timer while a menu is open — it would hide the chrome the
        // menu is anchored to.
        guard !menuOpen else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled {
                controlsVisible = false
            }
        }
        #endif
    }
}

// MARK: - Chrome primitives

/// The styled pill content rendered by `CtlChip`. On iPhone (compact width) only the
/// icon is shown; iPad keeps the full label so the wider bar has room.
private struct ChipLabel: View {
    let systemImage: String
    let label: String
    var sub: String? = nil
    var isActive: Bool = false

    @Environment(\.horizontalSizeClass) private var hSize

    private var iconOnly: Bool { hSize == .compact }

    var body: some View {
        Group {
            if iconOnly {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                    Text(label)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if let sub {
                        Text(sub)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, iconOnly ? 0 : 14)
        .frame(width: iconOnly ? 36 : nil, height: 36)
        .background(.white.opacity(isActive ? 0.22 : 0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .contentShape(Capsule())
    }
}

private struct CtlChip: View {
    let systemImage: String
    let label: String
    var sub: String? = nil
    let accessibilityLabel: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ChipLabel(systemImage: systemImage, label: label, sub: sub, isActive: isActive)
        }
        .tvChipButton()
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct GlassCircleButton: View {
    let systemImage: String
    var size: CGFloat = 44
    var iconSize: CGFloat = 19
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .glassEffect(.regular, in: Circle())
                // The whole glass circle must be tappable, not just the SF Symbol
                // glyph: .glassEffect adds no hit region, so without this the
                // transparent ring around small icons (return 46, zoom 36) misses
                // and the tap falls through to the chrome-toggle layer beneath.
                .contentShape(Circle())
        }
        .tvChipButton()
    }
}

/// Presents a track/speed/chapter menu as a popover on iPad (regular width) and a
/// bottom sheet on iPhone (compact width), gated so the two never race. One place for
/// the presentation chrome all four chips share — the only per-chip difference is the
/// sheet detents.
private struct TrackPresentation<MenuContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    var detents: Set<PresentationDetent> = [.medium, .large]
    @ViewBuilder var menu: () -> MenuContent

    @Environment(\.horizontalSizeClass) private var hSize

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
            .sheet(isPresented: $isPresented) {
                menu()
                    .presentationDetents(detents)
            }
        #else
        content
            .popover(isPresented: gated(whenRegular: true)) {
                menu()
                    .preferredColorScheme(.dark)
                    .presentationBackground(.clear)
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

    /// A binding that only fires for the matching width class, so the popover and the
    /// sheet never present at once.
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

/// AirPlay route button. Hosts an `AVRoutePickerView` inside a child view controller
/// whose horizontal size class we pin to `.regular` on iPad.
///
/// AVKit presents its route list from the nearest *presenting* view controller and
/// adapts popover→sheet on THAT controller's size class — never the picker view's.
/// Overriding the leaf view's `traitOverrides` (the first attempt) therefore did
/// nothing, so inside a `.fullScreenCover` the picker sheeted up from the bottom on
/// iPad. Wrapping the picker in a child VC and overriding *its* traits via
/// `setOverrideTraitCollection(_:forChild:)` makes the controller the picker lives
/// in — the one AVKit finds and presents from — report `.regular`, so the route list
/// anchors to the button. iPhone keeps the system bottom sheet (platform convention).
private struct AVRoutePickerViewRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> RoutePickerController {
        RoutePickerController()
    }

    func updateUIViewController(_ controller: RoutePickerController, context: Context) {
        controller.applyTraitOverride()   // idempotent; re-asserts after any trait flip
    }
}

/// Controller whose `view` IS the `AVRoutePickerView`, so it's the nearest view
/// controller in the responder chain when AVKit presents the route list — i.e. the
/// presenter whose `horizontalSizeClass` decides popover vs. bottom sheet. Pinning
/// its `traitOverrides` to `.regular` on iPad keeps the list an anchored popover.
private final class RoutePickerController: UIViewController {
    override func loadView() {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .white
        // Clear so the surrounding `.glassEffect(in: Circle())` is the visible backing.
        picker.backgroundColor = .clear
        // Rank video-capable receivers (Apple TV) above audio-only ones.
        picker.prioritizesVideoDevices = true
        view = picker
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyTraitOverride()
    }

    func applyTraitOverride() {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        traitOverrides.horizontalSizeClass = .regular
    }
}
