#if DEBUG
import Foundation
import CoreMedia
import os
import ParallaxCore
import ParallaxJellyfin
import ParallaxFileBrowse
import ParallaxPlayback

/// Drives one scripted Playback Lab session end to end: adds the SMB source
/// from the scenario config, resolves the named file through the real listing
/// path, presents it through `PlaybackPresenter` (so the resolver → engine
/// selection → engine chain is exactly the one a user tap takes), then executes
/// the scenario timeline against the live `PlayerViewModel` while sampling
/// telemetry beats. See `PlaybackLabScenario` for the command set and
/// `PlaybackLabTelemetry` for the output format.
@MainActor
final class PlaybackLabRunner {

    /// The active runner, set at launch when `-playbackLab <config-path>` is
    /// present. `PlayerView.beginSession` hands the freshly built SMB
    /// `PlayerViewModel` over via `attach` — the one seam the lab needs inside
    /// the normal presentation path.
    private(set) static var active: PlaybackLabRunner?

    private let scenario: PlaybackLabScenario
    private let deps: AppDependencies
    private let playback: PlaybackPresenter
    private let telemetry = PlaybackLabTelemetry()
    private var vm: PlayerViewModel?

    private enum LabError: LocalizedError {
        case fileNotFound(String)
        case playerNeverAppeared
        case playbackFailed(String)
        case timeout(String)

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let name): "lab file not found in the lab folder: \(name)"
            case .playerNeverAppeared: "PlayerView never attached a view model"
            case .playbackFailed(let diag): "playback failed: \(diag)"
            case .timeout(let what): "timed out waiting for \(what)"
            }
        }
    }

    private init(scenario: PlaybackLabScenario, dependencies: AppDependencies, playback: PlaybackPresenter) {
        self.scenario = scenario
        self.deps = dependencies
        self.playback = playback
    }

    /// Parses `-playbackLab <path>` and builds the runner, or nil when the
    /// argument is absent. Called once from `ParallaxApp`'s startup task after
    /// `ServerStore.load()`.
    static func makeIfRequested(
        dependencies: AppDependencies, playback: PlaybackPresenter
    ) -> PlaybackLabRunner? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-playbackLab"), args.indices.contains(i + 1) else { return nil }
        let url = URL(fileURLWithPath: args[i + 1])
        do {
            let scenario = try JSONDecoder().decode(PlaybackLabScenario.self, from: Data(contentsOf: url))
            let runner = PlaybackLabRunner(scenario: scenario, dependencies: dependencies, playback: playback)
            active = runner
            return runner
        } catch {
            ParallaxCore.Log.playback.error("playbackLab: unreadable config at \(url.path): \(error.localizedDescription)")
            return nil
        }
    }

    func attach(_ viewModel: PlayerViewModel) {
        vm = viewModel
    }

    func run() async {
        await telemetry.record("runStart", ["file": scenario.file, "path": scenario.path])
        let sampler = Task { await sampleBeats() }
        do {
            let ref = try await addSource()
            let item = try await resolveItem(ref: ref)
            if scenario.resume != true {
                // Deterministic start: a prior run's saved position would silently
                // shift what every scenario measures (see PlaybackLabScenario.resume).
                await SMBResumeStore.shared.clear(item.id)
            }
            playback.playSMB(item, ref: ref)
            try await waitForViewModel()
            for step in scenario.timeline {
                try await execute(step)
            }
            await telemetry.record("done")
        } catch {
            // AppError's localizedDescription flattens to "Error code N" — record
            // the diagnostic form; error taxonomy is part of what the lab debugs.
            let detail = (error as? AppError)?.diagnosticDescription ?? error.localizedDescription
            await telemetry.record("failed", ["error": detail])
        }
        sampler.cancel()
        await telemetry.close()
    }

    // MARK: - Setup

    private func addSource() async throws -> SMBServerRef {
        let server = scenario.server
        let data = SMBServerData(
            host: server.host,
            username: server.username,
            domain: server.domain ?? "",
            shares: [server.share]
        )
        // Idempotent across repeated runs: the deterministic ServerID makes
        // addSMBServer replace the existing row in place.
        let id = try await deps.serverStore.addSMBServer(data, password: server.password)
        return SMBServerRef(id: id, data: data)
    }

    /// Lists the lab folder through the real SMB listing path and maps the
    /// named file exactly like a browse-wall row would, so the ItemID/URL the
    /// resolver sees is indistinguishable from a user tap.
    private func resolveItem(ref: SMBServerRef) async throws -> Item {
        let lister = try await deps.makeSMBLister(ref)
        let source = SMBFileSource(lister: lister, host: ref.data.host, share: scenario.server.share, root: "")
        defer { Task { await source.disconnect() } }
        let entries: [SMBDirectoryEntry]
        do {
            entries = try await source.mediaFiles(in: scenario.path)
        } catch {
            // Record the raw underlying error before mapping — the domain#code
            // is the ground truth the mapped taxonomy compresses away.
            let ns = error as NSError
            await telemetry.record("listError", [
                "domain": ns.domain, "code": ns.code, "detail": ns.localizedDescription,
            ])
            throw SMBFileSource.mapListError(error, share: scenario.server.share, path: scenario.path)
        }
        guard let entry = entries.first(where: { $0.name == scenario.file }) else {
            throw LabError.fileNotFound(scenario.file)
        }
        return SMBFileSource.item(from: entry, share: scenario.server.share, in: scenario.path)
    }

    private func waitForViewModel(timeout: Duration = .seconds(15)) async throws {
        let deadline = ContinuousClock.now + timeout
        while vm == nil {
            guard ContinuousClock.now < deadline else { throw LabError.playerNeverAppeared }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Timeline

    private func execute(_ step: PlaybackLabScenario.Step) async throws {
        await telemetry.record("command", commandFields(step))
        let started = ContinuousClock.now
        switch step.cmd {
        case "waitPlaying":
            try await waitForPlaying(timeout: step.timeoutSeconds ?? 60)
        case "wait":
            try await Task.sleep(for: .seconds(step.seconds ?? 1))
        case "play":
            vm?.setPlaying(true)
        case "pause":
            vm?.setPlaying(false)
        case "seek":
            await vm?.seekPreservingTransport(to: labTime(step.toSeconds ?? 0))
        case "skip":
            if let vm {
                let current = vm.currentPosition.isNumeric ? vm.currentPosition.seconds : 0
                await vm.seekPreservingTransport(to: labTime(current + (step.bySeconds ?? 0)))
            }
        case "scrub":
            await scrub(to: step.toSeconds ?? 0)
        case "audioTrack":
            await selectAudioTrack(matching: step.name ?? "")
        case "subtitle":
            await selectSubtitle(matching: step.name ?? "")
        case "finish":
            playback.dismiss()
            try await Task.sleep(for: .seconds(1))
        default:
            await telemetry.record("unknownCommand", ["cmd": step.cmd])
        }
        let elapsed = ContinuousClock.now - started
        await telemetry.record("commandDone", [
            "cmd": step.cmd,
            "elapsedMs": Int(elapsed / .milliseconds(1)),
        ])
    }

    private func waitForPlaying(timeout: Double) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while true {
            switch vm?.phase {
            case .playing:
                return
            case .failed(let error):
                throw LabError.playbackFailed(error.diagnosticDescription)
            default:
                guard ContinuousClock.now < deadline else { throw LabError.timeout("playing phase") }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// UI-fidelity scrub: the same latch → drag-pause → commit → release
    /// sandwich `PlayerControlsView`'s scrubber performs. The pause→seek→play
    /// shape is load-bearing — it reproduces bugs a plain in-stream seek does
    /// not (the a22 flush-loop dropout engages on exactly this shape).
    private func scrub(to seconds: Double) async {
        guard let vm else { return }
        let wasPlaying = vm.isPlaying
        vm.beginScrubLatch(resumePlaying: wasPlaying)
        await vm.engine?.pause()
        // A beat of "drag time" so the pause lands before the commit, like a finger would.
        try? await Task.sleep(for: .milliseconds(300))
        await vm.commitScrubSeek(to: labTime(seconds), resume: wasPlaying)
        vm.endScrubLatch()
    }

    /// Selects an audio track by name substring through the HUD's exact path,
    /// recording the full inventory first — that record is the ground truth
    /// for "which tracks did the engine even see".
    private func selectAudioTrack(matching fragment: String) async {
        guard let vm else { return }
        let tracks = vm.availableAudioTracks
        await telemetry.record("audioTracks", [
            "available": tracks.map { "\($0.displayName) [\($0.detailLabel ?? "-")]" },
            "selected": vm.selectedAudioTrack?.displayName ?? "none",
        ])
        let lowered = fragment.lowercased()
        guard let match = tracks.first(where: {
            $0.displayName.lowercased().contains(lowered)
                || ($0.detailLabel?.lowercased().contains(lowered) ?? false)
        }) else {
            await telemetry.record("audioTrackMiss", ["wanted": fragment])
            return
        }
        await vm.selectAudioTrack(match)
        await telemetry.record("audioTrackSelected", ["name": match.displayName])
    }

    /// Selects a subtitle track by name substring through the HUD's exact path
    /// (nil-safe: an empty fragment or no match records the miss and leaves the
    /// current selection). Same inventory-record contract as `selectAudioTrack`.
    private func selectSubtitle(matching fragment: String) async {
        guard let vm else { return }
        let tracks = vm.availableSubtitleTracks
        await telemetry.record("subtitleTracks", [
            "available": tracks.map(\.displayName),
            "selected": vm.selectedSubtitleTrack?.displayName ?? "none",
        ])
        let lowered = fragment.lowercased()
        guard let match = tracks.first(where: { $0.displayName.lowercased().contains(lowered) }) else {
            await telemetry.record("subtitleMiss", ["wanted": fragment])
            return
        }
        await vm.selectSubtitleTrack(match)
        await telemetry.record("subtitleSelected", ["name": match.displayName])
    }

    private func labTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: max(0, seconds), preferredTimescale: 600)
    }

    private func commandFields(_ step: PlaybackLabScenario.Step) -> [String: any Sendable] {
        var fields: [String: any Sendable] = ["cmd": step.cmd]
        if let value = step.seconds { fields["seconds"] = value }
        if let value = step.toSeconds { fields["toSeconds"] = value }
        if let value = step.bySeconds { fields["bySeconds"] = value }
        if let value = step.timeoutSeconds { fields["timeoutSeconds"] = value }
        return fields
    }

    // MARK: - Telemetry beats

    /// 500 ms cadence: position/duration/transport/phase, plus a distinct
    /// `phaseChange` event on transitions so the driver can measure command →
    /// phase latencies without diffing beats.
    private func sampleBeats() async {
        var lastPhase = ""
        while !Task.isCancelled {
            if let vm {
                let phase = phaseLabel(vm.phase)
                if phase != lastPhase {
                    await telemetry.record("phaseChange", ["phase": phase])
                    lastPhase = phase
                }
                await telemetry.record("beat", [
                    "positionMs": milliseconds(vm.currentPosition),
                    "durationMs": milliseconds(vm.currentDuration),
                    "isPlaying": vm.isPlaying,
                    "phase": phase,
                    "stallScrim": vm.showsStallScrim,
                ])
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func milliseconds(_ time: CMTime) -> Int {
        time.isNumeric ? Int(time.seconds * 1000) : -1
    }

    private func phaseLabel(_ phase: PlayerViewModel.Phase) -> String {
        switch phase {
        case .idle: "idle"
        case .loading: "loading"
        case .playing: "playing"
        case .failed(let error): "failed: \(error.diagnosticDescription)"
        }
    }
}
#endif
