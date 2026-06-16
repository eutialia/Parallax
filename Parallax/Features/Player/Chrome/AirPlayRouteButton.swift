import SwiftUI
import AVKit
import UIKit

/// AirPlay route button. Hosts an `AVRoutePickerView` inside a child view controller
/// whose horizontal size class is pinned to `.regular` on iPad.
///
/// AVKit presents its route list from the nearest *presenting* view controller and
/// adapts popover→sheet on THAT controller's size class — never the picker view's.
/// Wrapping the picker in a child VC and overriding *its* traits makes the controller
/// the picker lives in report `.regular`, so the route list anchors to the button on
/// iPad. iPhone keeps the system bottom sheet (platform convention).
struct AirPlayRouteButton: UIViewControllerRepresentable {
    /// Render the picker functionally invisible (alpha ≈ 0, still tappable) so the
    /// caller can draw its own SF Symbol underneath. `AVRoutePickerView`'s internal
    /// button scales its glyph from the view's bounds AND paints its own backing
    /// platter — neither can be matched to a neighbouring symbol through public API,
    /// and the platter read as a boxed-in segment inside the split pill.
    var hidesSystemGlyph = false

    func makeUIViewController(context: Context) -> AirPlayRoutePickerController {
        AirPlayRoutePickerController(hidesSystemGlyph: hidesSystemGlyph)
    }

    func updateUIViewController(_ controller: AirPlayRoutePickerController, context: Context) {
        controller.applyTraitOverride()   // idempotent; re-asserts after any trait flip
    }
}

/// Controller whose `view` IS the `AVRoutePickerView`, so it's the nearest view
/// controller in the responder chain when AVKit presents the route list.
final class AirPlayRoutePickerController: UIViewController {
    private let hidesSystemGlyph: Bool

    init(hidesSystemGlyph: Bool = false) {
        self.hidesSystemGlyph = hidesSystemGlyph
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .white
        picker.backgroundColor = .clear     // let the surrounding glass be the backing
        picker.prioritizesVideoDevices = true
        if hidesSystemGlyph {
            // An empty mask renders nothing while leaving hit-testing fully intact
            // (masks affect rendering only). Low-alpha hiding was tried first and
            // rejected: the internal button's platter still ghosted at 0.015–0.02
            // over mid-tone footage (render-measured), and below 0.01 UIKit stops
            // hit-testing the view entirely.
            picker.mask = UIView()
        }
        view = picker
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyTraitOverride()
    }

    func applyTraitOverride() {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        traitOverrides.horizontalSizeClass = .regular
    }
}
