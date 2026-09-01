/// 0...1 is the player HUD's native coordinate: every fraction the reducer, the bar, the band
/// and the travel geometry pass around is a position along the track, and every one of them has
/// to survive an out-of-range input (a beat reporting past the duration, a pinned preview, a
/// drag translated off the end of the bar). One helper, so a site that forgets to clamp is
/// visibly missing something rather than quietly hand-rolling its own.
///
/// `nonisolated` so `PlayerHUDReducer` — a pure state machine callable from any context — can
/// use it under the app target's default `@MainActor` isolation.
nonisolated extension Double {
    var unitClamped: Double { min(max(self, 0), 1) }
}
