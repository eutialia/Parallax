import ParallaxCore
import SwiftUI
import UIKit

/// The app target's retained-log channels. Package-side channels live next to what they instrument
/// (`SMBDiagnostics`); these cover the things only the app can see — scene phase, memory pressure,
/// and the foreground recovery it drives.
enum AppDiagnostics {
    /// Launch, scene phase edges, memory warnings. The most important channel in the file for a
    /// wake-time crash: it is what dates the gap between the last record before sleep and the first
    /// one after it.
    static let lifecycle = Log.retained(category: "AppLifecycle")

    /// Watches the cooperative pool and the main actor for stalls — how a watchdog `SIGKILL`
    /// announces itself. That kill is uncatchable and leaves a log that looks exactly like a native
    /// crash, so these two numbers are the only thing that tells them apart. App-scoped so it runs
    /// for the whole session.
    static let stallMonitor = StallMonitor()

    #if DEBUG
    /// Crashes the process on purpose, so the crash-capture chain can be verified end to end.
    ///
    /// A real memory fault rather than `raise(SIGSEGV)`: only a genuine access violation produces the
    /// `si_code`/`si_addr` and the faulting frame that `CrashSentinel` records, so `raise` would test
    /// the handler while skipping the part most likely to be wrong. Address `0x8` on purpose — it is
    /// what the SMB teardown crash faulted on, so a test record is directly comparable to a real one.
    ///
    /// Never reached in Release: the only caller is behind `#if DEBUG` in `DiagnosticsView`.
    static func triggerTestCrash() {
        lifecycle.fault("deliberate test crash")
        UnsafeMutablePointer<Int>(bitPattern: 0x8)!.pointee = 0
    }
    #endif
}

extension View {
    /// Records every scene-phase edge into the retained log, with a wall-clock stamp.
    ///
    /// **Why at the app root.** A crash that only happens after the device sleeps needs the log to
    /// say where sleep and wake fell relative to everything else. Per-screen refresh modifiers
    /// (`refreshesOnForeground`) already watch scene phase, but each of them is conditional — covered
    /// views skip their turn — so none of them is a reliable record of what the SCENE did. This one
    /// is unconditional and mounted once.
    func recordsScenePhaseForDiagnostics() -> some View {
        modifier(ScenePhaseDiagnostics())
    }
}

private struct ScenePhaseDiagnostics: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase, initial: true) { previous, phase in
                AppDiagnostics.lifecycle.mark("scenePhase \(Self.name(previous)) → \(Self.name(phase))")
            }
            // The UIKit lifecycle notifications, NOT `scenePhase`, are what drive the stall monitor.
            //
            // `scenePhase` is published as part of the scene update the watchdog is timing, so on the
            // run we are trying to capture it is the thing that never arrives — arming off it meant
            // the monitor stayed silent through the whole fatal window. `willEnterForeground` fires
            // at the START of the wake, ahead of any SwiftUI phase, so it brackets that window from
            // outside instead of from within it.
            .task {
                await withTaskGroup(of: Void.self) { group in
                    for event in AppLifecycleEvent.allCases {
                        group.addTask {
                            for await _ in NotificationCenter.default.notifications(named: event.name) {
                                AppDiagnostics.lifecycle.mark(event.label)
                                await AppDiagnostics.stallMonitor
                                    .noteForegroundChanged(isForeground: event.isForeground)
                            }
                        }
                    }
                }
            }
            // Memory pressure is worth having on the timeline too: a jettison-adjacent launch behaves
            // differently from an ordinary one, and on tvOS the app is the first thing squeezed.
            // The async-sequence form (not `onReceive`) so this file needs no Combine, matching how
            // `ParallaxApp` already consumes notifications.
            .task {
                for await _ in NotificationCenter.default.notifications(
                    named: UIApplication.didReceiveMemoryWarningNotification
                ) {
                    AppDiagnostics.lifecycle.mark("memory warning")
                }
            }
            .task {
                await AppDiagnostics.stallMonitor.start()
                // Checked once the scene is up, which is late enough for VLCKit and AMSMB2 to have
                // initialised: if either of them replaced our signal dispositions, the absence of a
                // crash record in this file means nothing, and that has to be stated rather than
                // assumed. See `CrashSentinel.displacedSignals`.
                DiagnosticsLog.recordCrashHandlerState()
            }
    }

    /// `ScenePhase` has no useful `description`, and the raw value would print as an opaque enum in
    /// a file somebody has to read.
    private static func name(_ phase: ScenePhase) -> String {
        switch phase {
        case .background: "background"
        case .inactive: "inactive"
        case .active: "active"
        @unknown default: "unknown"
        }
    }
}

/// The four UIKit lifecycle edges, as data so one loop can watch all of them.
///
/// These are recorded ALONGSIDE `scenePhase` rather than instead of it, and the pairing is the
/// point: `willEnterForeground` with no `scenePhase → active` after it says the wake began and the
/// scene update never finished, which is precisely the shape of a scene-update watchdog kill.
private enum AppLifecycleEvent: CaseIterable {
    case willEnterForeground, didBecomeActive, willResignActive, didEnterBackground

    var name: Notification.Name {
        switch self {
        case .willEnterForeground: UIApplication.willEnterForegroundNotification
        case .didBecomeActive: UIApplication.didBecomeActiveNotification
        case .willResignActive: UIApplication.willResignActiveNotification
        case .didEnterBackground: UIApplication.didEnterBackgroundNotification
        }
    }

    /// Prefixed so these never read as `scenePhase` lines when the log is scanned by eye.
    var label: String {
        switch self {
        case .willEnterForeground: "uikit willEnterForeground"
        case .didBecomeActive: "uikit didBecomeActive"
        case .willResignActive: "uikit willResignActive"
        case .didEnterBackground: "uikit didEnterBackground"
        }
    }

    /// Whether the process is running rather than suspended after this edge. Only
    /// `didEnterBackground` means suspended — `willResignActive` still runs (it is what fires when
    /// a system overlay comes up), so sampling must continue through it.
    var isForeground: Bool { self != .didEnterBackground }
}
