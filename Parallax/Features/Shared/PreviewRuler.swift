#if DEBUG
import SwiftUI

/// Diagnostic ruler for measurement previews: pure-red 1pt rules at known pt
/// insets, so a `RenderPreview` snapshot carries its own ground truth.
/// `scripts/render-ruler.py` auto-detects these lines (its detector keys on
/// saturated #FF0000 — don't restyle the color) and reports every edge in pt,
/// which is what makes "does the platter land on the grid margin" a one-render,
/// one-command question instead of an eyeballing loop.
///
/// Pin the preview with `traits: .fixedLayout(width:height:)` and pass that
/// width to the script's `--pt-width`; prefer dark mode renders (best edge
/// contrast). Pattern lives in the "Sort button in toolbar" preview.
extension View {
    func previewRuler(
        leading: CGFloat? = nil,
        trailing: CGFloat? = nil,
        top: CGFloat? = nil,
        bottom: CGFloat? = nil
    ) -> some View {
        overlay {
            ZStack {
                if let leading {
                    rule(width: 1).padding(.leading, leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let trailing {
                    rule(width: 1).padding(.trailing, trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if let top {
                    rule(height: 1).padding(.top, top)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                if let bottom {
                    rule(height: 1).padding(.bottom, bottom)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    private func rule(width: CGFloat? = nil, height: CGFloat? = nil) -> some View {
        Rectangle()
            .fill(Color(red: 1, green: 0, blue: 0))
            .frame(width: width, height: height)
    }
}
#endif
