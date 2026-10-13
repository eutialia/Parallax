extension Clock {
    /// Time elapsed on this clock since the call. A type that holds `any Clock<Duration>` can't
    /// subtract two of its `now` readings, because the erased `Instant`s don't share a type; this
    /// opens the clock once and hands back plain durations.
    public func stopwatch() -> @Sendable () -> Duration {
        let start = now
        return { start.duration(to: self.now) }
    }
}
