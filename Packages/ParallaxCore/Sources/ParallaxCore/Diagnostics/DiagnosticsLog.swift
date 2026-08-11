import Darwin
import Foundation
import os

/// Severity of one retained diagnostics record. Mirrors the `os.Logger` levels the same call sites
/// use for Console, so a record reads the same in both places.
public enum DiagnosticsLevel: String, Sendable, CaseIterable {
    case debug
    case info
    case notice
    case error
    case fault

    /// Single letter used in the file, so the level never dominates a line's width.
    var symbol: String {
        switch self {
        case .debug: "D"
        case .info: "I"
        case .notice: "N"
        case .error: "E"
        case .fault: "F"
        }
    }

    var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .notice: .default
        case .error: .error
        case .fault: .fault
        }
    }

    /// Whether a record at this level is written to the retained FILE, as opposed to Console only.
    ///
    /// The file is byte-capped, and its whole value is that the records from just before a crash are
    /// still in it. Anything that fires per scrolled tile — a thumbnail borrow, a cache probe — would
    /// push a wake-time failure out of the file within one flick of the remote. So the cap is
    /// enforced by LEVEL, not by hoping call sites are restrained: `debug` and `info` go to Console
    /// and stop there, and only `notice` and above are retained. A call site that wants something in
    /// the file says `notice`, and that word now means "this must survive the process".
    var isRetained: Bool {
        switch self {
        case .debug, .info: false
        case .notice, .error, .fault: true
        }
    }
}

/// One retained run of the app, as seen from outside the process that wrote it.
public struct DiagnosticsSession: Sendable, Identifiable, Hashable {
    /// The file name, which is also the sort key (it leads with a zero-padded timestamp).
    public let id: String
    public let url: URL
    public let startedAt: Date
    public let byteCount: Int
    /// True for the session this process is writing.
    public let isCurrent: Bool
    /// The crash line `CrashSentinel` wrote, when this session ended in one. The single most
    /// important thing the list can show: which run died, and how.
    public let crashSummary: String?

    public var endedInCrash: Bool { crashSummary != nil }

    /// Public so the diagnostics screen's previews can stand one up. The real ones come from
    /// `DiagnosticsLog.sessions()`.
    public init(
        id: String,
        url: URL,
        startedAt: Date,
        byteCount: Int,
        isCurrent: Bool,
        crashSummary: String?
    ) {
        self.id = id
        self.url = url
        self.startedAt = startedAt
        self.byteCount = byteCount
        self.isCurrent = isCurrent
        self.crashSummary = crashSummary
    }
}

/// Retained on-device logging: a plain text file per app run, kept across launches, readable and
/// exportable from Settings.
///
/// **Why the unified log isn't enough.** `os.Logger` output is the right thing while a debugger or
/// Console is attached, and the wrong thing otherwise. An app can read back only its OWN live
/// process's entries (`OSLogStore(scope: .currentProcessIdentifier)`), so the run that CRASHED is
/// exactly the run whose log is unreachable — and on an Apple TV that went to sleep, no debugger was
/// ever attached to see it live. This writes the records that matter to a file the next launch can
/// still read, with `CrashSentinel` appending a stack when the run ends badly.
///
/// **What belongs in here.** Lifecycle and transition facts — scene phase edges, connection
/// checkout/teardown, the entry and exit of a native call that can hang. NOT per-item chatter: the
/// file is byte-capped, and a scroll's worth of thumbnail records would push the interesting lines
/// out. Anything sensitive is redacted at the CALL SITE, exactly as for Console: this file is meant
/// to be shared with a stranger.
///
/// **Storage.** `Library/Caches`, which is the only durable-ish location an app owns on tvOS. The
/// newest `retainedSessions` runs are kept and older ones deleted at startup.
public enum DiagnosticsLog {

    /// How many past runs to keep. Enough to hold a crash, the relaunch that followed it, and a
    /// couple of ordinary runs around them, without ever mattering on a cache volume.
    public static let retainedSessions = 5

    /// Defaults key for the on/off switch. On by default: the failures this exists for are the ones
    /// nobody thought to turn logging on before.
    private static let enabledDefaultsKey = "diagnostics.retainedLogging.enabled"

    private static let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var sink: DiagnosticsSink?
        var startInstant: ContinuousClock.Instant?
        var isEnabled = true
    }

    // MARK: - Lifecycle

    /// Opens this run's file, prunes older runs, writes the session header, and arms `CrashSentinel`.
    /// Call once, as early in launch as possible — records made before this are dropped.
    ///
    /// Never throws and never traps: a device that can't give us a log file gets an app with no
    /// diagnostics, not an app that fails to start.
    public static func start() {
        // Before every guard below: a dead-socket write must not kill the process even when
        // retained logging is off or the sink fails to open.
        CrashSentinel.ignoreSIGPIPE()

        guard isEnabled else { return }
        guard let directory = directoryURL() else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent(newSessionFileName())
        guard let sink = DiagnosticsSink(url: url) else { return }

        // The guard has to escape the FUNCTION, not just the lock closure — an early `return` inside
        // `withLock` only leaves the closure, so a second `start()` would fall through and write a
        // header to a descriptor nothing else ever uses. Latent while launch was the only caller;
        // live now that the settings toggle calls it too.
        let didOpen = state.withLock { state -> Bool in
            guard state.sink == nil else { return false }
            state.sink = sink
            state.startInstant = ContinuousClock().now
            return true
        }
        guard didOpen else { return }
        pruneOldSessions(in: directory, keeping: url)

        sink.appendUncapped(sessionHeader())
        CrashSentinel.install(writingTo: sink.descriptor)
    }

    /// Whether retained logging is on. Off stops new records AND leaves existing files alone — use
    /// `clear()` to remove them.
    public static var isEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: enabledDefaultsKey) != nil else { return true }
            return defaults.bool(forKey: enabledDefaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledDefaultsKey)
            state.withLock { $0.isEnabled = newValue }
            // Switching it ON has to open a sink NOW. `start()` runs once at launch and returns
            // early when the flag was off, so without this the toggle reads "On" while every record
            // is still dropped and `CrashSentinel` is still unarmed — and the next crash leaves no
            // file at all. That is precisely the situation somebody turns this on to capture.
            if newValue { start() }
        }
    }

    // MARK: - Recording

    /// Appends one record, if the level is retained at all (see `DiagnosticsLevel.isRetained`).
    /// Cheap when logging is off, unstarted, or below the retained floor: the message closure is
    /// never evaluated, so a call site can interpolate freely without paying for a disabled log.
    public static func record(
        category: String,
        level: DiagnosticsLevel,
        _ message: () -> String
    ) {
        guard level.isRetained else { return }
        let context: (sink: DiagnosticsSink, start: ContinuousClock.Instant)? = state.withLock { state in
            guard state.isEnabled, let sink = state.sink, let start = state.startInstant else { return nil }
            return (sink, start)
        }
        guard let context else { return }

        let elapsed = context.start.duration(to: ContinuousClock().now)
        context.sink.append("\(timestamp(elapsed)) \(level.symbol) [\(category)] \(threadLabel()) \(message())")
    }

    /// States whether the crash handlers are armed and still ours, for the run currently being
    /// written. Call once the third-party native stacks have had a chance to initialise — see
    /// `CrashSentinel.displacedSignals`.
    ///
    /// This exists because the ABSENCE of a crash record is evidence, and evidence is only usable if
    /// the reader can trust that a crash would have been recorded.
    public static func recordCrashHandlerState() {
        let displaced = CrashSentinel.displacedSignals()
        let state = displaced.isEmpty ? "all ours" : "DISPLACED: \(displaced.joined(separator: ","))"
        record(category: "CrashSentinel", level: .notice) {
            "handlers armed=\(CrashSentinel.isArmed) \(state)"
        }
    }

    /// Records a record plus the current wall-clock time — for the few edges where "when did this
    /// happen in the real world" is the point (scene phase changes, device wake). The per-record
    /// stamp is monotonic elapsed time, which is what orders a log but says nothing about the
    /// eight hours the device spent asleep in between.
    public static func recordWithWallClock(
        category: String,
        level: DiagnosticsLevel = .notice,
        _ message: () -> String
    ) {
        let now = ISO8601DateFormatter.diagnostics.string(from: Date())
        record(category: category, level: level) { "\(message()) at=\(now)" }
    }

    // MARK: - Reading back

    /// Every retained run, newest first. The current run is included and marked.
    public static func sessions() -> [DiagnosticsSession] {
        guard let directory = directoryURL() else { return [] }
        let currentURL = state.withLock { $0.sink?.url }
        let manager = FileManager.default
        let contents = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
                return DiagnosticsSession(
                    id: url.lastPathComponent,
                    url: url,
                    startedAt: values?.creationDate ?? .distantPast,
                    byteCount: values?.fileSize ?? 0,
                    isCurrent: url == currentURL,
                    crashSummary: crashSummary(of: url)
                )
            }
    }

    /// The text of one session, for the on-screen viewer. Bounded by the sink's own byte cap, so
    /// this is safe to hold in memory.
    public static func text(of session: DiagnosticsSession) -> String {
        (try? String(contentsOf: session.url, encoding: .utf8)) ?? ""
    }

    /// Writes every retained session into ONE file under `tmp` and returns it, ready to hand to a
    /// share sheet (iOS) or the handoff server (tvOS). Newest run first — a support request is
    /// almost always about the most recent one.
    ///
    /// Regenerated on each call rather than cached: the current session keeps growing, and a stale
    /// export that stops just before the interesting part is worse than no export.
    public static func exportReport() throws -> URL {
        let stamp = fileStampFormatter.string(from: Date())
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Parallax-Diagnostics-\(stamp).txt")

        // Enumerated ONCE: `sessions()` scans the directory and reads every file looking for a crash
        // marker, so calling it per line of the header would re-read the whole store.
        let sessions = sessions()
        var report = "Parallax diagnostics export \(ISO8601DateFormatter.diagnostics.string(from: Date()))\n"
        report += "sessions: \(sessions.count)\n"
        for session in sessions {
            report += "\n\n========================================\n"
            report += "session \(session.id)"
            report += session.isCurrent ? " (current)" : ""
            report += session.endedInCrash ? " [CRASHED]" : ""
            report += "\n========================================\n"
            report += text(of: session)
        }
        try report.write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    /// Deletes every retained session except the one being written. The live file stays because its
    /// descriptor is held open (and by `CrashSentinel`) — unlinking it would leave the process
    /// writing to a file nobody can find.
    public static func clear() {
        guard let directory = directoryURL() else { return }
        let currentURL = state.withLock { $0.sink?.url }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        for url in contents where url != currentURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Session file bookkeeping

    private static func directoryURL() -> URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    /// Leads with a sortable timestamp so plain lexical ordering is chronological, and carries the
    /// pid so two launches in the same second can't collide on one file.
    private static func newSessionFileName() -> String {
        "session-\(fileStampFormatter.string(from: Date()))-\(getpid()).log"
    }

    private static func pruneOldSessions(in directory: URL, keeping current: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        let obsolete = contents
            .filter { $0.pathExtension == "log" && $0 != current }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .dropFirst(max(0, retainedSessions - 1))
        for url in obsolete {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Scans a file for `CrashSentinel`'s marker and returns the line carrying it. Whole-file read is
    /// fine: the sink caps a session well below anything worth streaming.
    ///
    /// Package-internal rather than private so a test can drive it against a fixture file: this is
    /// what decides whether a run is shown as crashed, and there is no other way to observe it
    /// without actually crashing the test process.
    static func crashSummary(of url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first { $0.contains(CrashSentinel.crashMarker) }
            .map(String.init)
    }

    // MARK: - Formatting

    private static func sessionHeader() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let bundleID = Bundle.main.bundleIdentifier ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString

        return """
        ================ Parallax diagnostics session ================
        started: \(ISO8601DateFormatter.diagnostics.string(from: Date()))
        app: \(version) (\(build))  bundle: \(bundleID)
        os: \(os)  model: \(hardwareModel())
        pid: \(getpid())
        \(CrashSentinel.imageManifest())
        --- records: [+elapsed seconds] LEVEL [category] thread message ---
        """
    }

    /// `hw.machine` — the raw model identifier (`AppleTV14,1`, `iPhone17,1`). Read through `sysctl`
    /// rather than UIKit so this stays a plain Foundation package.
    ///
    /// In a simulator `hw.machine` reports the HOST's architecture (`arm64`), which reads as a
    /// nonsense device; the simulator publishes the model it is pretending to be in the environment
    /// instead, and using it keeps a simulator log from looking like it came from mystery hardware.
    private static func hardwareModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "\(simulated) (Simulator)"
        }
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &value, &size, nil, 0) == 0 else { return "?" }
        return String(cString: value)
    }

    /// `+SSSS.mmm` — seconds since the session started, on a clock that KEEPS RUNNING while the
    /// device sleeps (`ContinuousClock`). That is the whole point on tvOS: the gap between the last
    /// record before sleep and the first one after it is the evidence that a wake happened.
    private static func timestamp(_ elapsed: Duration) -> String {
        let components = elapsed.components
        let milliseconds = components.attoseconds / 1_000_000_000_000_000
        return String(format: "[+%7lld.%03lld]", components.seconds, milliseconds)
    }

    /// `main`, or the mach port of whichever thread this is. libsmb2's callbacks land on AMSMB2's own
    /// queue, so "which thread" is often the difference between a normal teardown and a race.
    private static func threadLabel() -> String {
        Thread.isMainThread ? "main" : "t\(pthread_mach_thread_np(pthread_self()))"
    }

    /// `nonisolated(unsafe)` because `DateFormatter` isn't `Sendable` but IS documented as thread-safe
    /// for formatting once configured — and it is configured here, once, and never mutated again.
    /// Building one per record instead would cost more than everything else this type does.
    nonisolated(unsafe) private static let fileStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

extension ISO8601DateFormatter {
    /// Shared, never mutated after creation — see `DiagnosticsLog.fileStampFormatter` for why the
    /// unchecked opt-out is the honest annotation rather than a workaround.
    nonisolated(unsafe) static let diagnostics = ISO8601DateFormatter()
}
