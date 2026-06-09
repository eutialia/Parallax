#if os(tvOS)
import SwiftUI
import UIKit

/// Captures raw Siri-Remote **presses** (press-typed taps = directional clicks,
/// Select, Menu) and classifies them into `RemoteEvent`s for the HUD reducer. Analog
/// pans live in `TVPanCatcher`, which is window-attached and stays mounted in every
/// HUD state.
///
/// This view is mounted only on the floor and during scrubbing — `PlayerView`
/// unmounts it in `.fullHUD` so SwiftUI's focus engine owns the chips natively (a
/// focus-stealing UIView left in the hierarchy is what blocked chip focus, and a
/// *sibling* view can't intercept Menu once a chip is focused anyway — presses go
/// up the focused view's responder chain, not to siblings). So while mounted it
/// always captures: it's the sole focusable item, holds focus, and owns every press
/// including Menu (Back on the floor / scrub states).
///
/// NOT unit-tested: focus/press behavior depends on the focus engine and physical
/// remote, which the simulator doesn't reproduce. Verified on device.
struct TVRemoteInputView: UIViewControllerRepresentable {
    let onEvent: (RemoteEvent) -> Void

    func makeUIViewController(context: Context) -> RemoteInputController {
        let controller = RemoteInputController()
        controller.onEvent = onEvent
        return controller
    }

    func updateUIViewController(_ controller: RemoteInputController, context: Context) {
        controller.onEvent = onEvent
    }
}

/// The adapter's root view — focusable so it claims the remote whenever it's mounted.
final class RemoteCaptureView: UIView {
    override var canBecomeFocused: Bool { true }
}

final class RemoteInputController: UIViewController {
    var onEvent: ((RemoteEvent) -> Void)?

    override func loadView() {
        let v = RemoteCaptureView()
        v.backgroundColor = .clear
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Directional + select + menu CLICKS (physical presses, not touches).
        addClickTap(.leftArrow,  { [weak self] in self?.onEvent?(.click(.left)) })
        addClickTap(.rightArrow, { [weak self] in self?.onEvent?(.click(.right)) })
        addClickTap(.upArrow,    { [weak self] in self?.onEvent?(.click(.up)) })
        addClickTap(.downArrow,  { [weak self] in self?.onEvent?(.click(.down)) })
        addClickTap(.select,     { [weak self] in self?.onEvent?(.select) })
        addClickTap(.menu,       { [weak self] in self?.onEvent?(.menu) })
    }

    private func addClickTap(_ type: UIPress.PressType, _ handler: @escaping () -> Void) {
        let tap = ClosureTap(handler: handler)
        tap.allowedPressTypes = [NSNumber(value: type.rawValue)]
        view.addGestureRecognizer(tap)
    }
}

/// A `UITapGestureRecognizer` that fires a closure (no external target needed).
private final class ClosureTap: UITapGestureRecognizer {
    private let handler: () -> Void
    init(handler: @escaping () -> Void) {
        self.handler = handler
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(fire))
    }
    @objc private func fire() { handler() }
}

// MARK: - Window-level analog pan capture

/// Captures the remote's **indirect-touch pans** (analog swipes) and reports them as
/// `RemoteEvent`s. tvOS delivers indirect touches to the *focused* view's responder
/// chain, so a sibling overlay never sees them once SwiftUI chrome holds focus — but
/// the window is an ancestor of every focused view, so recognizers attached there
/// observe pans in **every** HUD state, including `.fullHUD` (that's what lets a
/// swipe on the focused scrubber drop into analog scrub). `PlayerView` mounts this
/// once for the whole playback surface so an in-flight pan keeps streaming deltas
/// across floor↔scrub↔fullHUD transitions — a recognizer added mid-gesture would
/// miss the touch that already began.
struct TVPanCatcher: UIViewRepresentable {
    /// Points-of-pan → normalised-progress conversion. Tuned on device.
    let progressPerPoint: Double
    let onEvent: (RemoteEvent) -> Void

    func makeUIView(context: Context) -> PanCatcherView {
        let v = PanCatcherView()
        v.isHidden = true   // inert placeholder — the recognizers live on the window
        v.onEvent = onEvent
        v.progressPerPoint = progressPerPoint
        return v
    }

    func updateUIView(_ v: PanCatcherView, context: Context) {
        v.onEvent = onEvent
        v.progressPerPoint = progressPerPoint
    }
}

final class PanCatcherView: UIView {
    var onEvent: ((RemoteEvent) -> Void)?
    var progressPerPoint: Double = 0.0008

    private enum PanAxis { case undecided, horizontal, vertical }
    private var panAxis: PanAxis = .undecided

    /// On the Siri Remote a CLICK is a physical press of the trackpad while the finger
    /// is still resting on it, so the indirect-touch pan keeps emitting `.changed` for
    /// the rest of that touch. Without this, a Select that confirms a scrub is followed
    /// by trailing pan deltas that re-enter `swipeScrub` from the floor — and because the
    /// engine is mid-seek (isPlaying == false) at that instant, the new scrub captures
    /// `wasPlaying: false` and its confirm seeks WITHOUT resuming → video stuck paused.
    /// So once any press fires (`PressSentinel`), swallow the rest of the current pan;
    /// a genuinely new gesture (`.began`) clears it.
    private var panSuppressed = false

    private lazy var pan: UIPanGestureRecognizer = {
        let g = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        g.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        g.cancelsTouchesInView = false   // observe only — never starve the focus engine
        return g
    }()
    private lazy var press = PressSentinel { [weak self] in self?.panSuppressed = true }

    private weak var attachedWindow: UIWindow?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard attachedWindow !== window else { return }
        attachedWindow?.removeGestureRecognizer(pan)
        attachedWindow?.removeGestureRecognizer(press)
        attachedWindow = window
        window?.addGestureRecognizer(pan)
        window?.addGestureRecognizer(press)
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            panSuppressed = false   // a fresh gesture reclaims scrub authority
            panAxis = .undecided
        case .changed:
            if panSuppressed { return }   // trailing motion after a click — ignore
            let t = g.translation(in: g.view)
            if panAxis == .undecided {
                guard abs(t.x) > 8 || abs(t.y) > 8 else { return }
                panAxis = abs(t.x) >= abs(t.y) ? .horizontal : .vertical
                if panAxis == .vertical { onEvent?(.swipeVertical) }   // reveal once
            }
            if panAxis == .horizontal {
                // Non-linear: scale the per-frame delta by how fast the touch is moving,
                // so a slow drag scrubs fine and a fast flick covers ground.
                let speed = abs(Double(g.velocity(in: g.view).x))   // pt/s
                let delta = Double(t.x) * progressPerPoint * scrubGain(forSpeed: speed)
                onEvent?(.swipeHorizontal(deltaProgress: delta))
                g.setTranslation(.zero, in: g.view)   // report incremental deltas
            }
        case .ended, .cancelled, .failed:
            panAxis = .undecided
        default:
            break
        }
    }

    /// Pointer-style scrub acceleration. `progressPerPoint` is the gain at
    /// `referenceSpeed`; this scales it from `minGain` (slow drag → accurate small
    /// nudges) up to `maxGain` (fast flick → quick big jumps). These four are the
    /// swipe-feel tuning knobs:
    /// - lower `referenceSpeed` → acceleration kicks in sooner (more of the range feels fast)
    /// - raise `minGain` if slow scrubbing feels sluggish; raise `maxGain` for snappier flicks
    /// - raise `gamma` to widen the gap between slow and fast.
    private func scrubGain(forSpeed speed: Double) -> Double {
        let referenceSpeed = 800.0   // pt/s where gain == 1 (the confirmed linear feel)
        let minGain = 0.2
        let maxGain = 3.0
        let gamma = 1.5
        let gain = pow(speed / referenceSpeed, gamma)
        return min(maxGain, max(minGain, gain))
    }
}

/// Observes every remote press without consuming it (fails immediately) — its only
/// job is to end the current pan's scrub authority (see `panSuppressed` above).
/// Window-attached alongside the pan, so it sees presses no matter which view holds
/// focus (the window is always in the focused view's responder chain).
private final class PressSentinel: UIGestureRecognizer {
    private let onPress: () -> Void
    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        onPress()
        state = .failed
    }
}
#endif
