import ParallaxTestScaling
import Testing

/// Polls `condition` until it holds — and FAILS if it never does.
///
/// For the fire-and-forget teardown paths only — `pool.discard`, the `listShares` teardown and the
/// graveyard's release all hop through an unstructured `Task`, so there is nothing to await on. The
/// condition is `async` so a test can poll actor state (`pool.condemnedCount`) as easily as the
/// world's plain ledgers.
///
/// Scheduler turns first, then a wall-clock tail for anything a `Task.yield` alone does not drive.
///
/// Exhaustion records an Issue at the CALL SITE (`#_sourceLocation`) rather than returning quietly:
/// a silent give-up left the following `#expect` to report the failure, and where the poll was the
/// whole assertion — "the plot is eventually freed" — nothing reported it at all.
func untilSettled(
    _ condition: @Sendable () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    for _ in 0..<1_000 {
        if await condition() { return }
        await Task.yield()
    }
    let deadline = ContinuousClock().now.advanced(by: CITimeScale.seconds(5))
    while ContinuousClock().now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record(
        "the condition never settled within 1,000 scheduler turns and \(CITimeScale.seconds(5))",
        sourceLocation: sourceLocation
    )
}
