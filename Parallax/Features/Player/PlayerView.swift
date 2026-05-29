import SwiftUI
import ParallaxCore
import ParallaxJellyfin

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
                    if let engine = vm.engine {
                        AVPlayerViewControllerHost(engine: engine)
                            .ignoresSafeArea()
                    }
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                case .playing:
                    if let engine = vm.engine {
                        AVPlayerViewControllerHost(engine: engine)
                            .ignoresSafeArea()
                    }
                case .failed(let error):
                    errorOverlay(error, vm: vm)
                }
            } else {
                ProgressView().tint(.white)
            }
        }
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
