import CoreGraphics

/// How far a centered control moves so a fold doesn't split it. The HIG (Designing for iPhone Duo,
/// Reserved regions) asks to move only what the fold would split, not to re-lay the screen. The side
/// is fixed by choice, not by whichever is nearer, so the control never flips sides as the fold
/// shifts: a fold running across the screen sends it below, onto the half that lies on the table in
/// a tabletop pose; a fold running down the screen sends it to the right.
nonisolated public enum FoldClearance {
    /// The offset that takes `content` clear of every rect in `folds`, all in one coordinate space.
    /// Zero when nothing overlaps.
    public static func offset(for content: CGRect, avoiding folds: [CGRect]) -> CGSize {
        folds.reduce(.zero) { shift, fold in
            let placed = content.offsetBy(dx: shift.width, dy: shift.height)
            guard placed.intersects(fold) else { return shift }
            return fold.width >= fold.height
                ? CGSize(width: shift.width, height: shift.height + fold.maxY - placed.minY)
                : CGSize(width: shift.width + fold.maxX - placed.minX, height: shift.height)
        }
    }
}
