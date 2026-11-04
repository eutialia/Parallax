import CoreGraphics
import Testing
import ParallaxFeatures

/// Geometry measured on the iPhone Duo simulator: the inner display's fold is a 40pt band (its
/// margins included) across the middle of the 669 × 951 portrait screen.
@Suite("Fold clearance")
struct FoldClearanceTests {
    private let acrossPortrait = CGRect(x: 0, y: 455.5, width: 669, height: 40)
    private let downLandscape = CGRect(x: 455.5, y: 0, width: 40, height: 669)

    @Test("a control centered on a fold across the screen drops to just below it")
    func acrossFold() {
        let transport = CGRect(x: 234.5, y: 440.5, width: 200, height: 70)
        #expect(FoldClearance.offset(for: transport, avoiding: [acrossPortrait])
                == CGSize(width: 0, height: 55))
    }

    @Test("a control centered on a fold down the screen moves to just right of it")
    func downFold() {
        let transport = CGRect(x: 375.5, y: 299.5, width: 200, height: 70)
        #expect(FoldClearance.offset(for: transport, avoiding: [downLandscape])
                == CGSize(width: 120, height: 0))
    }

    @Test("a control clear of the fold stays put; one on it moves")
    func clearStaysPut() {
        let clear = CGRect(x: 234.5, y: 600, width: 200, height: 70)
        let onFold = CGRect(x: 234.5, y: 470, width: 200, height: 70)
        #expect(FoldClearance.offset(for: clear, avoiding: [acrossPortrait]) == .zero)
        #expect(FoldClearance.offset(for: onFold, avoiding: [acrossPortrait])
                == CGSize(width: 0, height: 25.5))
    }
}
