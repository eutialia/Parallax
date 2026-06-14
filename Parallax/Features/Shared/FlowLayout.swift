import SwiftUI

/// A wrapping flow layout: places subviews left to right and breaks to the next line when the
/// next subview would exceed the proposed width. Each line is as tall as its tallest subview.
/// Used for chip rows (e.g. genres in the detail info card) so they fill the available width
/// instead of overflowing or scrolling.
struct FlowLayout: Layout {
    var spacing: CGFloat = Space.s8

    /// Subview ideal sizes, measured once. The `Layout` cache is the supported way to avoid
    /// re-measuring every subview in `sizeThatFits` AND `placeSubviews` on each pass.
    func makeCache(subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func updateCache(_ cache: inout [CGSize], subviews: Subviews) {
        cache = subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let lines = wrap(into: maxWidth, sizes: cache)
        let height = lines.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, lines.count - 1))
        let usedWidth = lines.map(\.width).max() ?? 0
        // Report the proposed width when it's a real number (so the chips left-align in the
        // column); fall back to the intrinsic width for nil OR infinite proposals — never
        // propagate an infinite width up the tree.
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite {
            width = proposed
        } else {
            width = usedWidth
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) {
        let lines = wrap(into: bounds.width, sizes: cache)
        var y = bounds.minY
        for line in lines {
            var x = bounds.minX
            for index in line.indices {
                let size = cache[index]
                // Never propose more than the container width — keeps a single chip wider than the
                // column from bleeding past the trailing edge (it compresses/truncates instead).
                let placeWidth = min(size.width, bounds.width)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: placeWidth, height: size.height)
                )
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Group subview indices into lines that fit `maxWidth`, using the pre-measured `sizes`.
    private func wrap(into maxWidth: CGFloat, sizes: [CGSize]) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in sizes.indices {
            let size = sizes[index]
            let advance = line.indices.isEmpty ? size.width : size.width + spacing
            if !line.indices.isEmpty, line.width + advance > maxWidth {
                lines.append(line)
                line = Line(indices: [index], width: size.width, height: size.height)
            } else {
                line.indices.append(index)
                line.width += advance
                line.height = max(line.height, size.height)
            }
        }
        if !line.indices.isEmpty { lines.append(line) }
        return lines
    }
}
