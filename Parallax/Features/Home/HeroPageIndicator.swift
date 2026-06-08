import SwiftUI
import UIKit

/// Native page dots + the iOS 17 `UIPageControlTimerProgress` pill, decoupled from any
/// pager. It only reflects `currentPage`, owns the auto-advance timer, and reports a tick
/// via `onAdvance` — the carousel itself is a SwiftUI crossfade (`HomeHeroCarousel`), so
/// this is the one piece that still needs UIKit (SwiftUI has no progress-pill analog).
struct HeroPageIndicator: UIViewRepresentable {
    let numberOfPages: Int
    let currentPage: Int
    let autoAdvanceInterval: TimeInterval
    /// True while the user is dragging — freezes the auto-advance fill under their finger.
    let isPaused: Bool
    let reduceMotion: Bool
    let onAdvance: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onAdvance: onAdvance) }

    func makeUIView(context: Context) -> UIPageControl {
        let pc = UIPageControl()
        pc.currentPageIndicatorTintColor = .white
        pc.pageIndicatorTintColor = UIColor.white.withAlphaComponent(0.45)
        // tvOS resolves `.automatic` to `.prominent`, wrapping the dots in a bright glass
        // capsule that fights the artwork. `.minimal` drops it to bare dots — and it's already
        // the iOS default, so this stays platform-neutral (no `#if`).
        pc.backgroundStyle = .minimal
        pc.hidesForSinglePage = true
        // Display-only: never steal taps meant for the leading Play/Favorite buttons.
        pc.isUserInteractionEnabled = false
        // Dark halo so the white dots / progress pill stay legible over bright (even
        // pure-white) artwork — the layer shadow is cast by the composited indicators.
        pc.layer.masksToBounds = false
        pc.layer.shadowColor = UIColor.black.cgColor
        pc.layer.shadowOpacity = 0.5
        pc.layer.shadowRadius = 3
        pc.layer.shadowOffset = .zero
        context.coordinator.pageControl = pc
        context.coordinator.apply(pages: numberOfPages, page: currentPage,
                                  interval: autoAdvanceInterval, paused: isPaused, reduceMotion: reduceMotion)
        return pc
    }

    func updateUIView(_ pc: UIPageControl, context: Context) {
        context.coordinator.onAdvance = onAdvance
        context.coordinator.apply(pages: numberOfPages, page: currentPage,
                                  interval: autoAdvanceInterval, paused: isPaused, reduceMotion: reduceMotion)
    }

    @MainActor
    final class Coordinator: NSObject, UIPageControlTimerProgressDelegate {
        weak var pageControl: UIPageControl?
        var onAdvance: () -> Void
        private var timer: UIPageControlTimerProgress?

        init(onAdvance: @escaping () -> Void) { self.onAdvance = onAdvance }

        func apply(pages: Int, page: Int, interval: TimeInterval, paused: Bool, reduceMotion: Bool) {
            guard let pc = pageControl else { return }
            pc.numberOfPages = pages
            pc.currentPage = page

            guard pages > 1, !reduceMotion else {
                // No auto-advance: drop the pill, keep the (static) dots.
                timer?.pauseTimer()
                pc.progress = nil
                timer = nil
                return
            }

            if paused {
                // Freeze the fill under the finger and tear our timer down, so resuming
                // recreates it below with a fresh dwell for the settled page.
                timer?.pauseTimer()
                timer = nil
            } else {
                // Recreate whenever the timer was torn down (first run or after a pause); a
                // continuously running timer self-resets its fill as it auto-advances.
                if timer == nil {
                    let progress = UIPageControlTimerProgress(preferredDuration: interval)
                    progress.delegate = self
                    progress.resetsToInitialPageAfterEnd = true
                    pc.progress = progress
                    timer = progress
                }
                timer?.resumeTimer()
            }
        }

        func pageControlTimerProgress(_ progress: UIPageControlTimerProgress, shouldAdvanceToPage page: Int) -> Bool {
            onAdvance()
            return true
        }
    }
}
