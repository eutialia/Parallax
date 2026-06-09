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
