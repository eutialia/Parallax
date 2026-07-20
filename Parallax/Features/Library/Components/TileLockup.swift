import SwiftUI

/// The one place the artwork-tile "lockup" platform split lives: a tvOS `.borderless` button label
/// wants its caption as its OWN label child (so the native lockup slides the text clear of the
/// focus-lifted artwork), while iOS/iPadOS want a single contained view (so callers can attach
/// `.task` / `.contentShape` without them fanning out).
///
/// - tvOS: emits the artwork and caption as SIBLING label children — the body is a two-statement
///   `@ViewBuilder` (a `TupleView`), so an enclosing `.borderless` button sees two children and
///   applies the caption-avoidance nudge. A contained `VStack` here suppresses the nudge and the
///   focused frame lands on the text (LockupTextSpikeScreen rows B/C, device-verified 2026-07).
///   Nested custom-View layers stay transparent to that walk (the SMB tile already stacks
///   `SMBThumbnailTile.Lockup → MediaTile.Lockup → …` and the nudge survives), so wrapping the
///   siblings in this shared view changes nothing the engine sees.
/// - iOS: a single `TileContainedStack` — the contained form callers modify.
///
/// CRITICAL invariants (all device-verified history — don't "simplify" them away):
/// (a) tvOS must stay tuple/Group-transparent — never introduce a wrapping container around the
///     siblings; (b) never attach a modifier to the sibling *tuple* from inside (it distributes onto
///     each sibling — a `.task` would run twice); per-sibling modifiers (the task on the artwork
///     only, the flatten-a11y label/hidden split) are fine and required; (c) iOS stays one contained
///     view; (d) each call site's exact accessibility structure is reproduced via `accessibility`;
///     (e) a no-task lockup emits the BARE artwork view (no wrapper) — the shape all tvOS device
///     verification was done against.
///
/// Two configurations are exercised and verified: `.childrenOwn` + optional task
/// (`MediaTile.Lockup`) and `.flatten` + content shape (`FolderBrowseCard`). Other combinations
/// (e.g. flatten + task) should work but have never been rendered — verify before relying on one.
struct TileLockup<Artwork: View, Caption: View>: View {
    /// How the tile's accessibility is composed — the two shapes the call sites need.
    enum Accessibility {
        /// The artwork/caption views already carry their own a11y (e.g. `MediaThumbnail` owns its
        /// folded label, `MediaTile.metadataRow` is already `.accessibilityHidden`). The lockup adds
        /// nothing on either platform.
        case childrenOwn
        /// The lockup flattens the tile into one labelled element: on tvOS the label rides the
        /// artwork sibling and the caption is hidden (the sibling layout the nudge needs); on iOS the
        /// contained view is one ignored-children element with the label (the folder-card shape).
        case flatten(label: String)
    }

    // Defaults live on the init alone — a custom init suppresses the memberwise one, so
    // property-level defaults here would be dead (and could silently drift from the real ones).
    let artwork: Artwork
    let caption: Caption
    let accessibility: Accessibility
    /// iOS-only tap region for the whole contained tile (thumbnail + caption + the gap between),
    /// matching the folder card / SMB tile. nil = no `contentShape` (the artwork owns the tap).
    let iOSContentShapeRadius: CGFloat?
    /// An async load that must run exactly once: it rides the ARTWORK sibling on tvOS (attached to
    /// the tuple it would fire per-sibling) and the whole contained view on iOS. Presence must be
    /// STATIC per call site — the present/absent branches are `_ConditionalContent`, so an id that
    /// toggles nil↔value at runtime flips the branch, tearing down and re-establishing `.task(id:)`
    /// and re-firing the "exactly once" load mid-flight.
    let taskID: AnyHashable?
    let task: (@MainActor () async -> Void)?

    init(
        artwork: Artwork,
        @ViewBuilder caption: () -> Caption,
        accessibility: Accessibility = .childrenOwn,
        iOSContentShapeRadius: CGFloat? = nil,
        taskID: AnyHashable? = nil,
        task: (@MainActor () async -> Void)? = nil
    ) {
        self.artwork = artwork
        self.caption = caption()
        self.accessibility = accessibility
        self.iOSContentShapeRadius = iOSContentShapeRadius
        self.taskID = taskID
        self.task = task
    }

    var body: some View {
        #if os(tvOS)
        tvArtwork
        tvCaption
        #else
        contained
        #endif
    }

    #if os(tvOS)
    /// The artwork with its once-only task attached — or the BARE artwork when there is none
    /// (invariant e: the no-task shape is what the tvOS nudge was device-verified against; a
    /// permanent no-op wrapper would be an unverified delta). The branch is static per call site.
    @ViewBuilder private var taskedArtwork: some View {
        if let taskID, let task {
            artwork.task(id: taskID) { await task() }
        } else {
            artwork
        }
    }

    /// The artwork sibling, carrying the once-only task (per invariant b, on the sibling not the
    /// tuple) and — under `.flatten` — the tile's a11y label.
    @ViewBuilder private var tvArtwork: some View {
        switch accessibility {
        case .childrenOwn: taskedArtwork
        case .flatten(let label): taskedArtwork.accessibilityLabel(label)
        }
    }

    @ViewBuilder private var tvCaption: some View {
        switch accessibility {
        case .childrenOwn: caption
        case .flatten: caption.accessibilityHidden(true)
        }
    }
    #else
    /// The single contained view iOS callers modify: the stack, then (in the folder-card order)
    /// the tap shape, the flattened a11y element, and the whole-tile task.
    @ViewBuilder private var contained: some View {
        let stack = TileContainedStack(artwork: artwork) { caption }
            .modifier(OptionalContentShapeModifier(radius: iOSContentShapeRadius))
            .modifier(FlattenAccessibilityModifier(label: flattenLabel))
        if let taskID, let task {
            stack.task(id: taskID) { await task() }
        } else {
            stack
        }
    }

    /// The a11y label to flatten the contained tile under, or nil to leave the children's own a11y.
    private var flattenLabel: String? {
        if case .flatten(let label) = accessibility { return label }
        return nil
    }
    #endif
}

/// The contained artwork-over-caption stack — `MediaTile.body` and `TileLockup`'s iOS form both
/// render THIS, so the two paths a tile can take on iOS (plain vs `.lockup()`) can't drift apart.
struct TileContainedStack<Artwork: View, Caption: View>: View {
    let artwork: Artwork
    @ViewBuilder let caption: () -> Caption

    var body: some View {
        VStack(alignment: .leading, spacing: MediaTile.metadataGap) {
            artwork
            caption()
        }
    }
}

// MARK: - Optional-modifier helpers
//
// Each wraps an if/else over differently-modified content — that IS `_ConditionalContent`, but it's
// harmless here because presence (radius / label) is fixed per call site and never toggles at
// runtime; the payoff is that `contained` stays one linear chain instead of nesting conditionals.

#if !os(tvOS)
/// iOS tap region for the whole tile; skipped (artwork owns the tap) when no radius is set.
private struct OptionalContentShapeModifier: ViewModifier {
    let radius: CGFloat?

    func body(content: Content) -> some View {
        if let radius {
            content.contentShape(.rect(cornerRadius: radius))
        } else {
            content
        }
    }
}

/// Collapses the contained tile into one labelled element when a `label` is supplied (the
/// folder-card shape); leaves it alone otherwise (the artwork/caption already own their a11y).
private struct FlattenAccessibilityModifier: ViewModifier {
    let label: String?

    func body(content: Content) -> some View {
        if let label {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        } else {
            content
        }
    }
}
#endif
