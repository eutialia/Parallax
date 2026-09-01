import CoreMedia

/// The whole answer to "where is the picture, where is the bar promising it will be, and what
/// is in flight" — one value, published by `PlayerViewModel`, consumed by the bar.
///
/// It replaces an agreement between five owners (a hold that carried an origin it never read,
/// two derivations over it, a float-tolerance re-derivation of "is this still the newest", and
/// four view-level `@State`s sequencing a lifecycle by hand). The invariant it makes explicit:
/// there is at most ONE seek in flight; it has a position the picture is at, a position the bar
/// promises, and a stage; and its `id` — not a pair of rendered fractions — is its identity.
///
/// It is deliberately not the release policy. `SeekHold` still decides which engine beat ends
/// the window (`absorb`); the flight decides what the window MEANS.
nonisolated struct SeekFlight: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        /// A gesture owns the bar: `requested` rides the finger (or the tvOS swipe) and
        /// nothing has been dispatched yet.
        case previewing
        /// The commit is out and the engine has not acknowledged it. The picture is still at
        /// `played` — this is the window the reload scrim covers.
        case committed
        /// The engine is projecting off its own seek target. `.projected` is display-safe by
        /// contract ("the picture is at, or running from, this position"), so the honest
        /// position is the published clock again — but the seek is still unresolved, and only
        /// an `.observed` beat ends the flight.
        case landing
    }

    /// Monotonic, and THE identity of this crossing. Every animation keys on it, so a duration
    /// republish mid-hold (a re-anchor's `applyDuration`) moves the fractions without restarting
    /// anything; and a superseded commit gets a fresh one, so the bar cannot keep painting a
    /// span the user has already abandoned. An integer compare, not a float tolerance.
    let id: UInt64
    /// A — the position the flight started from, which is where the picture stays until the
    /// engine takes the seek. `stage == .landing` is exactly the point this stops being the
    /// honest answer (see `PlayerViewModel.concretePosition`).
    let played: CMTime
    /// B — where the bar is promising the picture will be: the finger's preview while
    /// `.previewing`, the committed target after.
    let requested: CMTime
    var stage: Stage
}

/// The flight as the BAR sees it: the committed jump in 0...1 track fractions, with the
/// flight's identity attached. The fractions are a pure render input — a duration republish
/// moves them — which is why the crossing, the comet and the newest-wins test all key on `id`
/// and never on the pair.
struct SeekSpan: Equatable {
    let id: UInt64
    let delta: SeekDelta
}
