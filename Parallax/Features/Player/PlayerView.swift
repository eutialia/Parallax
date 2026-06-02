import SwiftUI
import ParallaxCore
import ParallaxJellyfin
import ParallaxPlayback

struct PlayerView: View {
    let item: ItemDetail
    let session: Session

    @Environment(AppDependencies.self) private var deps
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: PlayerViewModel?
    #if DEBUG
    @State private var showDebugHUD = false
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let vm = viewModel {
                switch vm.phase {
                case .idle, .loading:
                    videoHost(vm)
                case .playing:
                    videoHost(vm)
                    SubtitleOverlayView(vm: vm)
                    PlayerControlsView(vm: vm) { dismiss() }
                case .failed(let error):
                    errorOverlay(error, vm: vm)
                }
            }
        }
        // Loading + reload visual: a frosted, shimmering cover over the frozen frame,
        // replacing the spinner. On a transcode track switch the engine is paused +
        // reused, so the last frame stays put under the frost until the new stream
        // plays; the cover fades out when playback resumes.
        .overlay {
            if showsReloadCover {
                TrackReloadCover()
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
                .font(.title3)
                .foregroundStyle(.white.opacity(0.55))
                .padding(12)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showDebugHUD)
        #endif
        .ignoresSafeArea()
        .task {
            if viewModel == nil {
                let info = await deps.playbackInfoFactory(session)
                let engineFactory = deps.playbackEngineFactory
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
                    engineFactory: { id in engineFactory(id) },
                    audioSession: deps.audioSession
                )
                viewModel = vm
                await vm.start(item: item)
            }
        }
        .onDisappear {
            let vm = viewModel
            Task { await vm?.stop() }
        }
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

    @ViewBuilder
    private func errorOverlay(_ error: AppError, vm: PlayerViewModel) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.white)
            Text(error.userMessage)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Retry") {
                    Task { await vm.retry(item: item) }
                }
                .buttonStyle(.borderedProminent)
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
        }
        .padding(40)
    }
}
