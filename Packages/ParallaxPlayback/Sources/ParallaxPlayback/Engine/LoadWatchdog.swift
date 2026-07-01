import Foundation

/// A one-shot load deadline shared by both playback engines. Without it the only ways out of
/// `.loading` are an explicit engine error or a throwing `load()` — so a source that opens but
/// never produces a first frame (a truncated container the demuxer can't finish, a dead SMB
/// mount, a wedged HLS segment fetch) leaves the player permanently, uncontrollably stuck on the
/// loading scrim. `VLCThumbnailer` already ships a 20s deadline for exactly this class; the
/// engines had none.
///
/// Usage: `arm(onTimeout:)` when entering `.loading`; `disarm()` at the first sign of life (the
/// first real beat / `.ready`) and on teardown. If neither happens within `timeout`, `onTimeout`
/// fires once on the MainActor — the engine yields `.failed(.assetNotPlayable)` so the existing
/// error scrim + offline-recovery take over instead of an endless spinner.
///
/// No SwiftUI/Combine (package rule): a bare `Task` + `Duration`. `@MainActor` because the engines
/// are, and the timeout closure mutates engine state.
@MainActor
final class LoadWatchdog {
    private var task: Task<Void, Never>?
    private let timeout: Duration

    /// 30s default: longer than the thumbnailer's 20s decode budget (a cold transcode/seek can
    /// legitimately take longer to first-frame than a single snapshot), short enough that a truly
    /// stuck load surfaces an error before the user gives up. Wants a slow-network device pass.
    init(timeout: Duration = .seconds(30)) {
        self.timeout = timeout
    }

    /// Start (or restart) the deadline. A prior armed timer is superseded so only the latest fires.
    func arm(onTimeout: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { [timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            onTimeout()
        }
    }

    /// Cancel the pending deadline (first beat arrived, or teardown). Idempotent.
    func disarm() {
        task?.cancel()
        task = nil
    }
}
