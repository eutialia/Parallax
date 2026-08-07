import Testing

/// Polls `condition` across scheduler turns until it holds — and FAILS if it never does.
///
/// For the fire-and-forget teardown paths only — `pool.discard`, the `listShares` teardown and the
/// graveyard's release all hop through an unstructured `Task`, so there is nothing to await on. The
/// condition is `async` so a test can poll actor state (`pool.condemnedCount`) as easily as the
/// world's plain ledgers.
///
/// Exhaustion records an Issue at the CALL SITE (`#_sourceLocation`) rather than returning quietly:
/// a silent give-up left the following `#expect` to report the failure, and where the poll was the
/// whole assertion — "the plot is eventually freed" — nothing reported it at all.
///
/// For the opposite shape (waiting out a condition that must NEVER hold), use `settleScheduler`:
/// this one would flag the very behaviour such a test is proving.
func untilSettled(
    _ condition: @Sendable () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    for _ in 0..<1_000 {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record(
        "the condition never settled within 1,000 scheduler turns",
        sourceLocation: sourceLocation
    )
}

/// Yields the scheduler `turns` times and asserts nothing — for giving a detached Task every chance
/// to do something the test claims it will NOT do (a fuse that must stay a no-op). The caller's own
/// `#expect` afterwards is the assertion.
func settleScheduler(turns: Int = 20) async {
    for _ in 0..<turns { await Task.yield() }
}
