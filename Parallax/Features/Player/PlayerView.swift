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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let vm = viewModel {
                switch vm.phase {
                case .idle, .loading:
                    videoHost(vm)
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                case .playing:
                    videoHost(vm)
                    PlayerControlsView(vm: vm) { dismiss() }
                case .failed(let error):
                    errorOverlay(error, vm: vm)
                }
            } else {
                ProgressView().tint(.white)
            }
        }
        .ignoresSafeArea()
        .task {
            if viewModel == nil {
                let info = await deps.playbackInfoFactory(session)
                let engineFactory = deps.playbackEngineFactory
                let vm = PlayerViewModel(
                    deviceProfileBuilder: deps.deviceProfileBuilder,
                    playbackInfo: info,
                    resolve: { id, caps, start in
                        try await info.resolve(item: id, capabilities: caps, startTime: start)
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
