#if !os(tvOS)
import SwiftUI
import UIKit

/// Symmetric fade for the lights window — same duration in and out.
private let subtitleLightsFadeDuration: TimeInterval = 0.45

/// Floats `content` in a passthrough `UIWindow` ABOVE everything — including an iPad form-sheet, which
/// an app-root `.overlay` can't clear (the sheet presents over RootView, so the overlay lands behind
/// it). Touches pass straight through (the window is purely decorative), and the content fades in/out.
/// Attach as a zero-impact `.background` on the app root; it grabs that view's window scene to host the
/// overlay window one level up.
struct WindowOverlay<OverlayContent: View>: UIViewRepresentable {
    var isPresented: Bool
    @ViewBuilder var content: () -> OverlayContent

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Defer so `uiView.window` is populated on first layout.
        DispatchQueue.main.async {
            context.coordinator.update(isPresented: isPresented, anchor: uiView, content: content)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var window: PassthroughWindow?
        /// Built LAZILY from the first real content so it's typed `UIHostingController<OverlayContent>`,
        /// not `<AnyView>`. Type erasure makes SwiftUI treat each `rootView` reassignment as a brand-new
        /// root and REMOUNT the overlay, so a live style change would hard-cut — the `.smooth` animation
        /// inside `SubtitleStageLights` only fires when SwiftUI DIFFS a same-type root in place.
        private var host: UIHostingController<OverlayContent>?
        /// Latest desired state. A fade-out completion that lands AFTER a re-present must not hide a
        /// window that's meant to be visible again (the quick exit→re-enter race).
        private var presented = false

        func update(isPresented: Bool, anchor: UIView, content: () -> OverlayContent) {
            presented = isPresented
            if isPresented {
                guard let scene = anchor.window?.windowScene else { return }
                let host = resolveHost(content())   // create once, else update the rootView in place
                host.view.backgroundColor = .clear
                host.view.isUserInteractionEnabled = false
                let w = ensureWindow(scene, host: host)
                if w.isHidden {
                    w.isHidden = false
                    host.view.alpha = 0
                }
                // Fade UP to fully visible. This covers BOTH a fresh show (alpha just set to 0) and
                // reversing an in-flight fade-out — a running exit has already driven the model `alpha`
                // to 0, so `< 1` catches that case and animates back from the on-screen value.
                if host.view.alpha < 1 {
                    UIView.animate(withDuration: subtitleLightsFadeDuration) { host.view.alpha = 1 }
                }
            } else if let w = window, let host, !w.isHidden {
                UIView.animate(withDuration: subtitleLightsFadeDuration, animations: { host.view.alpha = 0 }) { [weak self] _ in
                    // Only hide if we're STILL meant to be gone; a re-present mid-fade cancelled the exit.
                    if self?.presented == false { w.isHidden = true }
                }
            }
        }

        func teardown() {
            window?.isHidden = true
            window?.windowScene = nil
            window = nil
            host = nil
        }

        /// Create the typed host on first use, or push the new content into the existing one (an
        /// in-place `rootView` update SwiftUI can diff — preserving the live-style glide).
        private func resolveHost(_ content: OverlayContent) -> UIHostingController<OverlayContent> {
            if let host {
                host.rootView = content
                return host
            }
            let h = UIHostingController(rootView: content)
            window?.rootViewController = h
            host = h
            return h
        }

        private func ensureWindow(_ scene: UIWindowScene, host: UIHostingController<OverlayContent>) -> PassthroughWindow {
            if let window, window.windowScene === scene { return window }
            let w = PassthroughWindow(windowScene: scene)
            w.windowLevel = .normal + 1          // above the app's main window (and its sheets)
            w.backgroundColor = .clear
            w.rootViewController = host
            window = w
            return w
        }
    }
}

/// A window that never handles touches — every hit test falls through to the windows below, so the
/// dimmed menu beneath stays fully interactive.
final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}
#endif
