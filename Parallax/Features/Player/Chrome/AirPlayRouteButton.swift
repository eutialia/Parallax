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
///
/// The picker renders nothing but stays tappable, so the caller draws its own SF Symbol
/// underneath. `AVRoutePickerView`'s internal button scales its glyph from the view's
/// bounds AND paints its own backing platter — neither can be matched to a neighbouring
/// symbol through public API, and the platter read as a boxed-in segment inside the
/// split pill.
struct AirPlayRouteButton: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> AirPlayRoutePickerController {
        AirPlayRoutePickerController()
    }

    func updateUIViewController(_ controller: AirPlayRoutePickerController, context: Context) {
        controller.applyTraitOverride()   // idempotent; re-asserts after any trait flip
    }
}

/// Controller whose `view` IS the `AVRoutePickerView`, so it's the nearest view
/// controller in the responder chain when AVKit presents the route list.
final class AirPlayRoutePickerController: UIViewController {
    override func loadView() {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .white
        picker.backgroundColor = .clear     // let the surrounding glass be the backing
        picker.prioritizesVideoDevices = true
        // An empty mask renders nothing while leaving hit-testing fully intact
        // (masks affect rendering only). Low-alpha hiding was tried first and
        // rejected: the internal button's platter still ghosted at 0.015–0.02
        // over mid-tone footage (render-measured), and below 0.01 UIKit stops
        // hit-testing the view entirely.
        picker.mask = UIView()
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
