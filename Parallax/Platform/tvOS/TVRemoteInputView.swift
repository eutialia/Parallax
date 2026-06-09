#if os(tvOS)
import SwiftUI
import UIKit

/// Captures raw Siri-Remote input and classifies it into `RemoteEvent`s for the
/// HUD reducer. The split is the documented one: **indirect-touch pans = swipes**
/// (analog), **press-typed taps = directional clicks**.
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
    /// Points-of-pan → normalised-progress conversion. Tuned on device.
    let progressPerPoint: Double
    let onEvent: (RemoteEvent) -> Void

    func makeUIViewController(context: Context) -> RemoteInputController {
        let controller = RemoteInputController()
        controller.onEvent = onEvent
        controller.progressPerPoint = progressPerPoint
        return controller
    }

    func updateUIViewController(_ controller: RemoteInputController, context: Context) {
        controller.onEvent = onEvent
        controller.progressPerPoint = progressPerPoint
    }
}

/// The adapter's root view — focusable so it claims the remote whenever it's mounted.
final class RemoteCaptureView: UIView {
    override var canBecomeFocused: Bool { true }
}

final class RemoteInputController: UIViewController {
    var onEvent: ((RemoteEvent) -> Void)?
    var progressPerPoint: Double = 0.0008

    private enum PanAxis { case undecided, horizontal, vertical }
    private var panAxis: PanAxis = .undecided

    override func loadView() {
        let v = RemoteCaptureView()
        v.backgroundColor = .clear
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Analog swipe: indirect touches from the remote's touch surface.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        view.addGestureRecognizer(pan)

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

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            panAxis = .undecided
        case .changed:
            let t = g.translation(in: view)
            if panAxis == .undecided {
                guard abs(t.x) > 8 || abs(t.y) > 8 else { return }
                panAxis = abs(t.x) >= abs(t.y) ? .horizontal : .vertical
                if panAxis == .vertical { onEvent?(.swipeVertical) }   // reveal once
            }
            if panAxis == .horizontal {
                // Non-linear: scale the per-frame delta by how fast the touch is moving,
                // so a slow drag scrubs fine and a fast flick covers ground.
                let speed = abs(Double(g.velocity(in: view).x))   // pt/s
                let delta = Double(t.x) * progressPerPoint * scrubGain(forSpeed: speed)
                onEvent?(.swipeHorizontal(deltaProgress: delta))
                g.setTranslation(.zero, in: view)   // report incremental deltas
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
#endif
