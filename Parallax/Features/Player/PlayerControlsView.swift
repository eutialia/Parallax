import SwiftUI
import CoreMedia
import ParallaxPlayback

/// Engine-agnostic player chrome. Overlaid on top of the video host view.
/// Reads `PlayerViewModel` state; calls `vm.selectAudioTrack` / `selectSubtitleTrack`.
///
/// The controls auto-hide after 3 seconds of inactivity. Tap anywhere to
/// show/hide (standard iOS/iPadOS player chrome convention).
struct PlayerControlsView: View {
    @Bindable var vm: PlayerViewModel
    let onDismiss: () -> Void

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>? = nil

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
    }

    @ViewBuilder
    private var controls: some View {
        VStack {
            HStack {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
                trackMenus
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Spacer()

            HStack(spacing: 40) {
                skipButton(seconds: -10, systemImage: "gobackward.10")
                playPauseButton
                skipButton(seconds: 30, systemImage: "goforward.30")
            }

            Spacer()

            scrubber
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        .background(
            LinearGradient(
                colors: [.black.opacity(0.7), .clear, .black.opacity(0.5)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

    private var isPlaying: Bool {
        if case .playing = vm.phase { return true }
        return false
    }

    @ViewBuilder
    private var playPauseButton: some View {
        Button {
            resetHideTimer()
            Task {
                if isPlaying {
                    await vm.engine?.pause()
                } else {
                    await vm.engine?.play()
                }
            }
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private func skipButton(seconds: Double, systemImage: String) -> some View {
        Button {
            resetHideTimer()
            Task {
                guard let engine = vm.engine else { return }
                let posSeconds = CMTimeGetSeconds(vm.currentPosition)
                let target = CMTime(
                    seconds: max(0, posSeconds + seconds),
                    preferredTimescale: 600
                )
                await engine.seek(to: target)
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private var scrubber: some View {
        let posSeconds = CMTimeGetSeconds(vm.currentPosition)
        let durSeconds = CMTimeGetSeconds(vm.currentDuration)
        let progress = durSeconds > 0 ? posSeconds / durSeconds : 0.0

        VStack(spacing: 4) {
            Slider(value: .init(get: { progress }, set: { newValue in
                resetHideTimer()
                guard let engine = vm.engine, durSeconds > 0 else { return }
                let target = CMTime(seconds: newValue * durSeconds, preferredTimescale: 600)
                Task { await engine.seek(to: target) }
            }))
            .tint(.white)

            HStack {
                Text(formatTime(posSeconds))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
                Spacer()
                Text(formatTime(durSeconds))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
            }
        }
    }

    @ViewBuilder
    private var trackMenus: some View {
        HStack(spacing: 12) {
            if !vm.availableAudioTracks.isEmpty {
                Menu {
                    ForEach(vm.availableAudioTracks, id: \.id) { track in
                        Button {
                            resetHideTimer()
                            Task { await vm.selectAudioTrack(track) }
                        } label: {
                            if vm.selectedAudioTrack?.id == track.id {
                                Label(track.displayName, systemImage: "checkmark")
                            } else {
                                Text(track.displayName)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "waveform")
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }

            if !vm.availableSubtitleTracks.isEmpty {
                Menu {
                    Button {
                        resetHideTimer()
                        Task { await vm.selectSubtitleTrack(nil) }
                    } label: {
                        if vm.selectedSubtitleTrack == nil {
                            Label("Off", systemImage: "checkmark")
                        } else {
                            Text("Off")
                        }
                    }
                    ForEach(vm.availableSubtitleTracks, id: \.id) { track in
                        Button {
                            resetHideTimer()
                            Task { await vm.selectSubtitleTrack(track) }
                        } label: {
                            if vm.selectedSubtitleTrack?.id == track.id {
                                Label(track.displayName, systemImage: "checkmark")
                            } else {
                                Text(track.displayName)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "captions.bubble")
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

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
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled {
                controlsVisible = false
            }
        }
    }
}
