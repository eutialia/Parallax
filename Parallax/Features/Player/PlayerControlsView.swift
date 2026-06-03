import SwiftUI
import AVKit
import CoreMedia
import ParallaxPlayback

/// Engine-agnostic player chrome, overlaid on the video host. Reads `PlayerViewModel`
/// state and drives transport, scrubbing, track selection, speed, and aspect-fill.
///
/// The chrome is always white-on-dark (the player surface is an immersive "screening
/// room" over video, regardless of the app's light/dark appearance), so it uses
/// explicit `.white` and Liquid Glass materials rather than the light/dark color
/// tokens. The presented track menus DO follow the tokens — see `TrackMenu.swift` —
/// pinned to a dark scheme so they stay immersive.
///
/// Controls auto-hide after 3s of inactivity; tap anywhere to toggle. The auto-hide
/// is suspended while a track menu (popover/sheet) is open.
struct PlayerControlsView: View {
    @Bindable var vm: PlayerViewModel
    /// Whether the video is filling the screen (aspect-fill) vs fit. Owned by
    /// `PlayerView` (it owns the host); the expand chip toggles it.
    let isFilled: Bool
    let onToggleFill: () -> Void
    let onDismiss: () -> Void

    @Environment(\.horizontalSizeClass) private var hSize

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>? = nil
    @State private var isScrubbing = false
    @State private var scrubProgress: Double = 0
    /// Bumped on every drag start. The seek Task captures it and only clears
    /// `isScrubbing` if no newer drag began while its (possibly slow) seek was in
    /// flight — otherwise a rapid re-grab would snap the thumb to live playback.
    @State private var scrubGeneration = 0
    @State private var audioMenu = false
    @State private var subtitleMenu = false

    private var menuOpen: Bool { audioMenu || subtitleMenu }

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }

            if controlsVisible {
                controls
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .onAppear { scheduleHide() }
        // Resume the auto-hide once every menu closes; keep controls pinned while open.
        .onChange(of: menuOpen) { _, open in
            if open { hideTask?.cancel() } else { scheduleHide() }
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
        )
    }

    // MARK: - Top bar

    @ViewBuilder
    private var topBar: some View {
        HStack(alignment: .top, spacing: Space.s14) {
            GlassCircleButton(systemImage: "chevron.down", size: 46, iconSize: 20) { onDismiss() }

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

            if let engineLabel = vm.engineLabel, hSize == .regular {
                EngineBadge(text: engineLabel)
            }
            if vm.isVideoAirPlayAvailable {
                AVRoutePickerViewRepresentable()
                    .frame(width: 44, height: 44)
            }
            if vm.isPiPAvailable {
                GlassCircleButton(systemImage: "pip.enter", size: 40, iconSize: 18) {
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
                resetHideTimer()
                Task {
                    if isPlaying { await vm.engine?.pause() }
                    else { await vm.engine?.play() }
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 88, height: 88)
                    .glassEffect(.regular, in: Circle())
            }
            .buttonStyle(.plain)

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
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 66, alignment: .leading)

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

            Text(remaining > 0 ? "-\(formatTime(remaining))" : formatTime(durSeconds))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 66, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var chipRow: some View {
        HStack(spacing: 10) {
            if !vm.availableAudioTracks.isEmpty {
                CtlChip(
                    systemImage: "waveform",
                    label: vm.selectedAudioTrack?.displayName ?? "Audio",
                    isActive: audioMenu
                ) {
                    resetHideTimer()
                    audioMenu = true
                }
                .popover(isPresented: popoverBinding($audioMenu)) { audioMenuList }
                .sheet(isPresented: sheetBinding($audioMenu)) {
                    audioMenuList
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.regularMaterial)
                }
            }

            if !vm.availableSubtitleTracks.isEmpty {
                CtlChip(
                    systemImage: "captions.bubble",
                    label: "Subtitles",
                    sub: vm.selectedSubtitleTrack?.displayName ?? "Off",
                    isActive: subtitleMenu
                ) {
                    resetHideTimer()
                    subtitleMenu = true
                }
                .popover(isPresented: popoverBinding($subtitleMenu)) { subtitleMenuList }
                .sheet(isPresented: sheetBinding($subtitleMenu)) {
                    subtitleMenuList
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.regularMaterial)
                }
            }

            speedChip

            Spacer(minLength: 0)

            GlassCircleButton(
                systemImage: isFilled ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                size: 36,
                iconSize: 16
            ) {
                resetHideTimer()
                onToggleFill()
            }
        }
    }

    // MARK: - Speed

    private let speedOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    @ViewBuilder
    private var speedChip: some View {
        Menu {
            ForEach(speedOptions, id: \.self) { rate in
                Button {
                    resetHideTimer()
                    Task { await vm.setPlaybackRate(Float(rate)) }
                } label: {
                    if vm.playbackRate == Float(rate) {
                        Label(speedText(rate), systemImage: "checkmark")
                    } else {
                        Text(speedText(rate))
                    }
                }
            }
        } label: {
            ChipLabel(systemImage: "timer", label: speedText(Double(vm.playbackRate)), sub: nil, isActive: false)
        }
        // The speed picker is a system Menu with no open/close binding, so it can't
        // join `menuOpen`. Pin the chrome when it's tapped open; the rate buttons
        // reschedule the auto-hide on selection.
        .simultaneousGesture(TapGesture().onEnded { pinControls() })
    }

    /// Keep the chrome up indefinitely (used while a system Menu with no dismissal
    /// callback is open). A later `resetHideTimer()` re-arms the auto-hide.
    private func pinControls() {
        controlsVisible = true
        hideTask?.cancel()
    }

    private func speedText(_ rate: Double) -> String {
        let s = String(format: rate == rate.rounded() ? "%.0f" : "%g", rate)
        return s + "×"
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

    /// Shared presentation wrapper: scrollable, dark-pinned (so tokens resolve to the
    /// immersive dark palette), width-bounded for the popover (the sheet ignores width).
    /// No `presentationCompactAdaptation` here — it's shared by both the popover and
    /// the sheet, and forcing `.popover` would defeat the iPhone sheet's detents. The
    /// popover only ever presents in regular width (see `popoverBinding`), so it stays
    /// a popover natively; the sheet only ever presents in compact width.
    @ViewBuilder
    private func trackMenuChrome<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .padding(8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(idealWidth: 360)
        .frame(maxHeight: 520)
        .environment(\.colorScheme, .dark)
    }

    /// A popover binding that only fires in regular width (iPad). In compact width the
    /// flag drives the sheet instead, so the two presentations never race.
    private func popoverBinding(_ flag: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { flag.wrappedValue && hSize == .regular }, set: { flag.wrappedValue = $0 })
    }

    /// The compact-width (iPhone) counterpart: drives a bottom sheet.
    private func sheetBinding(_ flag: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { flag.wrappedValue && hSize != .regular }, set: { flag.wrappedValue = $0 })
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
        controlsVisible.toggle()
        if controlsVisible { scheduleHide() }
    }

    private func resetHideTimer() {
        if !controlsVisible { controlsVisible = true }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        // Don't start the timer while a menu is open — it would hide the chrome the
        // menu is anchored to.
        guard !menuOpen else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled {
                controlsVisible = false
            }
        }
    }
}

// MARK: - Chrome primitives

/// The styled pill content shared by `CtlChip` (a button) and the speed `Menu` label.
private struct ChipLabel: View {
    let systemImage: String
    let label: String
    var sub: String? = nil
    var isActive: Bool = false

    var body: some View {
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
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(.white.opacity(isActive ? 0.22 : 0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .contentShape(Capsule())
    }
}

private struct CtlChip: View {
    let systemImage: String
    let label: String
    var sub: String? = nil
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ChipLabel(systemImage: systemImage, label: label, sub: sub, isActive: isActive)
        }
        .buttonStyle(.plain)
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
        }
        .buttonStyle(.plain)
    }
}

private struct EngineBadge: View {
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(.white.opacity(0.85))
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(.black.opacity(0.3), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
    }
}

private struct AVRoutePickerViewRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
