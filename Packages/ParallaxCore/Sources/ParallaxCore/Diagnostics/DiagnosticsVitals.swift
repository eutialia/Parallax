import Darwin
import Foundation
import os

/// The process facts that explain a death the crash handler never saw.
///
/// **Why this exists.** A log that simply STOPS has two readings, and they lead to opposite fixes: a
/// native crash (which `CrashSentinel` would normally record), or a `SIGKILL`, which no handler can
/// catch and which therefore leaves the same silent ending. `SIGKILL` on Apple platforms comes from
/// two places worth telling apart — jetsam, when the process is over its memory limit, and the
/// watchdog, when it stops responding. Both are invisible in the app; both become obvious if the log
/// carries memory headroom and main-thread responsiveness alongside the timeline.
public enum DiagnosticsVitals {

    /// Compact vitals appended to every `mark`: memory headroom, memory in use, and thermal state.
    ///
    /// `os_proc_available_memory` is the number Apple actually measures against — it counts DOWN to
    /// zero as the app approaches its limit, so a last record showing a few MB left names jetsam as
    /// the killer without any guesswork.
    ///
    /// Thermal state is here because the watchdog allowance is WALL CLOCK, not CPU time: a device at
    /// `.serious` or `.critical` is being throttled hard, so work that comfortably fits in ten
    /// seconds on a cool device may not on a hot one. An on-device crash report has already shown
    /// this app killed at thermal level 9, which makes it a variable worth having on the timeline
    /// rather than a detail to recall afterwards.
    public static func summary() -> String {
        "mem=\(format(available())) free / \(format(footprint())) used thermal=\(thermalName())"
    }

    private static func thermalName() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    /// Bytes remaining before this process hits its jetsam limit.
    static func available() -> Int {
        Int(os_proc_available_memory())
    }

    /// Current physical footprint — the same figure jetsam scores the process on.
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint)
    }

    /// Whole megabytes. Deliberately not `ByteCountFormatStyle`: this string is appended to records
    /// that can be written from any thread at any moment, and a fixed unit keeps the column readable
    /// when the log is scanned by eye.
    private static func format(_ bytes: Int) -> String {
        "\(bytes / (1024 * 1024))MB"
    }
}

/// Watches for the two ways this app can stop responding, and records them separately.
///
/// **What it has to decide.** A watchdog `SIGKILL` and a native crash leave the same evidence in a
/// log — records stop, nothing else — but they are different bugs with different fixes. Worse, an
/// on-device report has already shown a scene-update watchdog kill in which the MAIN THREAD WAS
/// IDLE, parked in `CFRunLoopRun` at 0% CPU. So "is the main thread blocked?" is not a sufficient
/// question: it can be perfectly responsive while the app is still killed for not finishing a scene
/// update. Answering only that question would have recorded nothing at all for that kill.
///
/// So each cycle measures two independent delays:
///
///  - **pool delay** — how much longer than requested a `Task.sleep` took to resume. This is
///    Swift concurrency's COOPERATIVE POOL, which is only as wide as the core count; a handful of
///    tasks blocking in native code (a graceful SMB disconnect on a dead socket, a Network.framework
///    syscall in a degraded policy layer) starves it, and nothing else in the app can make progress.
///  - **main delay** — how long a hop onto the main actor took once the pool had resumed. This is
///    the classic blocked-main-thread.
///
/// Read together they separate three outcomes: pool starvation, a blocked main thread, or a kill
/// while BOTH were healthy — which would move suspicion off this app's threads entirely and onto
/// whatever the scene commit is waiting for.
///
/// It writes only when a delay exceeds the threshold, so a healthy run costs one wakeup per interval
/// and not a single line of the byte-capped file.
public actor StallMonitor {

    private let channel: DiagnosticsChannel
    private let interval: Duration
    private let threshold: Duration
    private var task: Task<Void, Never>?

    /// Bumped on every scene-phase change. A sample that spans a bump is DISCARDED.
    ///
    /// **Without this the monitor lies.** While the app is backgrounded the OS suspends the process,
    /// and a suspension landing inside a sample is billed to whichever half it interrupts —
    /// producing "stalls" that track the backgrounded duration rather than anything the app did.
    /// Both halves have now been caught doing it: a 2.36s background reported as `main=1.96s`, and
    /// later a background window reported as `pool=0.81s main=0.002s`. Neither was evidence.
    private var sceneGeneration = 0

    /// Whether the scene is in the FOREGROUND at all (active or merely inactive). Sampling is
    /// suspended entirely while it isn't — discarding samples that straddle a phase CHANGE was not
    /// enough, because a sample can sit wholly inside a background window and still be distorted by
    /// the suspension within it.
    ///
    /// The line is drawn at `background`, not at `active`, because that is where the OS actually
    /// suspends the process — and because `inactive` is the WHOLE POINT. A scene-update watchdog
    /// kill happens while the scene update is still running, so an app dying to one may never reach
    /// `active` at all. Gating on `active` meant the monitor stayed silent through exactly the
    /// window it exists to describe, and the resulting log looked identical to one where nothing
    /// was ever watching.
    private var isForeground = true

    /// While set, EVERY sample is recorded, not only the slow ones.
    ///
    /// A watchdog kill leaves a log that simply stops, and silence is ambiguous: it could mean the
    /// app was healthy right up to the kill, or that it froze and the monitor never ran again. An
    /// unconditional pulse across the window where the kill happens removes that ambiguity — if the
    /// beats continue to the last line, the app was alive and scheduling when it died; if they stop,
    /// whatever froze it froze at that record. Scoped to a few seconds after each foreground return
    /// rather than always on, so it costs nothing during ordinary use of a byte-capped file.
    private var pulseUntil: ContinuousClock.Instant?

    /// - Parameters:
    ///   - interval: how often to sample. One second is frequent enough to catch the seconds-long
    ///     stall that precedes a ten-second watchdog allowance running out, and rare enough to be free.
    ///   - threshold: the delay worth recording. Deliberately well BELOW the ten-second watchdog
    ///     allowance: the mechanism has to be observable on runs that survive, or confirming it
    ///     depends on reproducing a kill that only happens under the right load and thermal state.
    ///     A third of a second is far past ordinary scheduling noise and far short of fatal.
    ///     At one sample per second this can cost at most ~85 bytes/s of the capped file.
    public init(
        channel: DiagnosticsChannel = Log.retained(category: "Stall"),
        interval: Duration = .milliseconds(1000),
        threshold: Duration = .milliseconds(300)
    ) {
        self.channel = channel
        self.interval = interval
        self.threshold = threshold
    }

    /// Tell the monitor the scene moved into or out of the foreground. Called from the app's
    /// lifecycle observers — the package cannot see `ScenePhase` or `UIApplication` itself.
    ///
    /// Reaching the foreground starts the pulse, and it starts at the FIRST sign of a wake rather
    /// than at full activation, because the app may never get to full activation: that is what the
    /// kill we are chasing prevents.
    public func noteForegroundChanged(isForeground: Bool) {
        sceneGeneration += 1
        self.isForeground = isForeground
        pulseUntil = isForeground ? ContinuousClock().now.advanced(by: Self.pulseDuration) : nil
    }

    /// How long to pulse after reaching the foreground. Comfortably past the watchdog's ten-second
    /// allowance, so a kill always lands inside a pulsed window rather than just after one.
    private static let pulseDuration: Duration = .seconds(14)

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self, interval, threshold, channel] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                guard let self else { return }
                // Read BEFORE the sleep, not after. A phase change during the SLEEP is the case that
                // most needs discarding — the process is suspended across a device sleep and
                // `ContinuousClock` keeps counting — and a generation captured after the sleep can
                // no longer see that bump. Sampling it late once reported an eight-hour suspension
                // as an eight-hour pool stall, which is the exact conclusion this monitor exists to
                // test rather than to fabricate.
                let (wasForeground, generationAtStart) = await (self.isForeground, self.sceneGeneration)
                let beforeSleep = clock.now
                try? await Task.sleep(for: interval)
                let resumed = clock.now
                // Overshoot beyond the requested interval is the pool's own latency: the sleep
                // expired on time, so anything past it is the wait for a free cooperative thread.
                let poolDelay = beforeSleep.duration(to: resumed) - interval
                // Stamped INSIDE the main actor so only the hop ONTO it is counted. Stamping after
                // the closure returns also bills the hop back off main — which needs a free
                // cooperative thread — so a starved pool would inflate `main` as well as `pool` and
                // the two numbers would stop being independent, defeating the whole split.
                let mainDelay = resumed.duration(to: await MainActor.run { clock.now })

                // Only samples taken wholly inside one FOREGROUND stretch mean anything: a
                // backgrounded app is suspended, and the suspension lands in whichever half of the
                // sample it interrupts. Reporting that would be worse than reporting nothing.
                guard wasForeground, await self.isForeground,
                      await self.sceneGeneration == generationAtStart else { continue }

                let isPulsing = await self.isPulsing(at: clock.now)
                guard isPulsing || poolDelay >= threshold || mainDelay >= threshold else { continue }
                let label = isPulsing ? "pulse" : "STALL"
                channel.notice(
                    "\(label) pool=\(poolDelay) main=\(mainDelay) \(DiagnosticsVitals.summary())")
            }
        }
    }

    private func isPulsing(at instant: ContinuousClock.Instant) -> Bool {
        guard let pulseUntil else { return false }
        guard instant < pulseUntil else {
            self.pulseUntil = nil
            return false
        }
        return true
    }

    deinit {
        task?.cancel()
    }
}
