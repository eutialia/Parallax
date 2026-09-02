import Testing
@testable import Parallax

/// A reference duration whose click step lands on a binary-exact fraction, so the
/// effects' `Double` equality stays reliable in the click-seek assertions.
private let referenceDuration: Double = 100
/// What ONE left/right click moves, as a fraction of `referenceDuration` — derived
/// from the reducer's own step constant, never re-typed as 0.1.
private let clickStep = PlayerHUDTuning.clickStepSeconds / referenceDuration

/// The reducer branches on neither the transport nor a progress of its own — the still-frame
/// hold leaves the user's intent alone, and the target of every scrub is the model's shown
/// progress handed back in — so one context covers nearly every row.
private let baseCtx = ReduceContext(shownProgress: 0.5, durationSeconds: referenceDuration)
/// Close enough to 0:00 that one backward click has to clamp.
private let nearStart = ReduceContext(shownProgress: 0.05, durationSeconds: referenceDuration)

/// One cell of the state × event transition table.
private struct Transition: Sendable, CustomTestStringConvertible {
    let state: PlayerHUDState
    let event: RemoteEvent
    let ctx: ReduceContext
    let expected: PlayerHUDState
    let effects: [PlayerEffect]

    var testDescription: String {
        "\(state) + \(event) → \(expected) \(effects)"
    }
}

private let transitionTable: [Transition] = [
    // floor
    .init(state: .floor, event: .select, ctx: baseCtx, expected: .floor, effects: [.togglePlayPause]),
    .init(state: .floor, event: .playPause, ctx: baseCtx, expected: .floor, effects: [.togglePlayPause]),
    .init(state: .floor, event: .menu, ctx: baseCtx, expected: .floor, effects: [.exit]),
    .init(state: .floor, event: .idle, ctx: baseCtx, expected: .floor, effects: []),
    .init(state: .floor, event: .click(.up), ctx: baseCtx, expected: .fullHUD, effects: []),
    .init(state: .floor, event: .click(.down), ctx: baseCtx, expected: .fullHUD, effects: []),
    .init(state: .floor, event: .swipeHorizontal(deltaProgress: 0.02), ctx: baseCtx,
          expected: .swipeScrub(chrome: false), effects: [.holdStillFrame, .preview(progress: 0.5 + 0.02)]),
    // A click is a preview the model accumulates on (`shownProgress` is the model's virtual
    // position, so the second click steps from the first's target) and the view debounces.
    .init(state: .floor, event: .click(.left), ctx: baseCtx, expected: .clickSeek, effects: [.preview(progress: 0.5 - clickStep)]),
    .init(state: .floor, event: .click(.right), ctx: baseCtx, expected: .clickSeek, effects: [.preview(progress: 0.5 + clickStep)]),
    .init(state: .floor, event: .click(.left), ctx: nearStart, expected: .clickSeek, effects: [.preview(progress: 0)]),
    // clickSeek
    .init(state: .clickSeek, event: .click(.right), ctx: baseCtx, expected: .clickSeek, effects: [.preview(progress: 0.5 + clickStep)]),
    .init(state: .clickSeek, event: .swipeHorizontal(deltaProgress: 0.02), ctx: baseCtx,
          expected: .swipeScrub(chrome: false), effects: [.holdStillFrame, .preview(progress: 0.5 + 0.02)]),
    .init(state: .clickSeek, event: .click(.down), ctx: baseCtx, expected: .fullHUD, effects: []),
    .init(state: .clickSeek, event: .select, ctx: baseCtx, expected: .floor, effects: [.togglePlayPause]),
    .init(state: .clickSeek, event: .menu, ctx: baseCtx, expected: .floor, effects: []),
    .init(state: .clickSeek, event: .idle, ctx: baseCtx, expected: .floor, effects: []),
    // swipeScrub on the floor: commits carry the model's shown progress; Back cancels.
    .init(state: .swipeScrub(chrome: false), event: .swipeHorizontal(deltaProgress: -0.1), ctx: baseCtx,
          expected: .swipeScrub(chrome: false), effects: [.preview(progress: 0.5 - 0.1)]),
    .init(state: .swipeScrub(chrome: false), event: .select, ctx: baseCtx, expected: .floor, effects: [.seek(progress: 0.5), .releaseHold]),
    .init(state: .swipeScrub(chrome: false), event: .idle, ctx: baseCtx, expected: .floor, effects: [.seek(progress: 0.5), .releaseHold]),
    .init(state: .swipeScrub(chrome: false), event: .click(.up), ctx: baseCtx, expected: .fullHUD, effects: [.seek(progress: 0.5), .releaseHold]),
    .init(state: .swipeScrub(chrome: false), event: .menu, ctx: baseCtx, expected: .floor, effects: [.cancelPreview, .releaseHold]),
    .init(state: .swipeScrub(chrome: false), event: .playPause, ctx: baseCtx,
          expected: .floor, effects: [.seek(progress: 0.5), .releaseHold, .togglePlayPause]),
    // swipeScrub in the chrome: same cells, home is the full HUD.
    .init(state: .swipeScrub(chrome: true), event: .swipeHorizontal(deltaProgress: 0.1), ctx: baseCtx,
          expected: .swipeScrub(chrome: true), effects: [.preview(progress: 0.5 + 0.1)]),
    .init(state: .swipeScrub(chrome: true), event: .select, ctx: baseCtx, expected: .fullHUD, effects: [.seek(progress: 0.5), .releaseHold]),
    .init(state: .swipeScrub(chrome: true), event: .idle, ctx: baseCtx, expected: .fullHUD, effects: [.seek(progress: 0.5), .releaseHold]),
    .init(state: .swipeScrub(chrome: true), event: .menu, ctx: baseCtx, expected: .fullHUD, effects: [.cancelPreview, .releaseHold]),
    .init(state: .swipeScrub(chrome: true), event: .playPause, ctx: baseCtx,
          expected: .fullHUD, effects: [.seek(progress: 0.5), .releaseHold, .togglePlayPause]),
    // fullHUD: the focused scrubber's L/R and pans arrive here; the chrome never drops for them.
    .init(state: .fullHUD, event: .click(.left), ctx: baseCtx, expected: .fullHUD, effects: [.preview(progress: 0.5 - clickStep)]),
    .init(state: .fullHUD, event: .click(.right), ctx: baseCtx, expected: .fullHUD, effects: [.preview(progress: 0.5 + clickStep)]),
    .init(state: .fullHUD, event: .click(.up), ctx: baseCtx, expected: .fullHUD, effects: []),
    .init(state: .fullHUD, event: .select, ctx: baseCtx, expected: .fullHUD, effects: []),
    .init(state: .fullHUD, event: .swipeHorizontal(deltaProgress: 0.02), ctx: baseCtx,
          expected: .swipeScrub(chrome: true), effects: [.holdStillFrame, .preview(progress: 0.5 + 0.02)]),
    .init(state: .fullHUD, event: .menu, ctx: baseCtx, expected: .floor, effects: []),
    .init(state: .fullHUD, event: .idle, ctx: baseCtx, expected: .floor, effects: []),
    .init(state: .fullHUD, event: .playPause, ctx: baseCtx, expected: .fullHUD, effects: [.togglePlayPause]),
]

/// One cell of the state × predicate table: which surfaces a state mounts.
private struct SurfaceRow: Sendable, CustomTestStringConvertible {
    let state: PlayerHUDState
    let chromeUp: Bool
    let isAnalogScrub: Bool
    let dimsVideo: Bool

    var testDescription: String { "\(state)" }
}

private let surfaceTable: [SurfaceRow] = [
    .init(state: .floor, chromeUp: false, isAnalogScrub: false, dimsVideo: false),
    .init(state: .swipeScrub(chrome: false), chromeUp: false, isAnalogScrub: true, dimsVideo: true),
    .init(state: .swipeScrub(chrome: true), chromeUp: true, isAnalogScrub: true, dimsVideo: false),
    .init(state: .clickSeek, chromeUp: false, isAnalogScrub: false, dimsVideo: true),
    .init(state: .fullHUD, chromeUp: true, isAnalogScrub: false, dimsVideo: false),
]

/// One cell of the state × (landing, loading) table for the lone floor bar.
private struct FloorBarRow: Sendable, CustomTestStringConvertible {
    let state: PlayerHUDState
    let landing: Bool
    let loading: Bool
    let shows: Bool

    var testDescription: String { "\(state) landing:\(landing) loading:\(loading) → \(shows)" }
}

private let everyLandingLoading = [(false, false), (true, false), (false, true), (true, true)]

private let floorBarTable: [FloorBarRow] = everyLandingLoading.flatMap { landing, loading in
    [
        // The floor's own scrub surfaces own the bar outright — no model fact gates them.
        FloorBarRow(state: .swipeScrub(chrome: false), landing: landing, loading: loading, shows: true),
        FloorBarRow(state: .clickSeek, landing: landing, loading: loading, shows: true),
        // The bare floor keeps it only for a seek that is still landing, and never under
        // the reload cover.
        FloorBarRow(state: .floor, landing: landing, loading: loading, shows: landing && !loading),
        // The chrome brings its own scrubber.
        FloorBarRow(state: .swipeScrub(chrome: true), landing: landing, loading: loading, shows: false),
        FloorBarRow(state: .fullHUD, landing: landing, loading: loading, shows: false),
    ]
}

/// One cell of the (next state, event) → pending-click-step table.
private struct ClickStepRow: Sendable, CustomTestStringConvertible {
    let next: PlayerHUDState
    let event: RemoteEvent
    let expected: PendingClickStep

    var testDescription: String { "→ \(next) on \(event) ⇒ \(expected)" }
}

private let clickStepTable: [ClickStepRow] = [
    .init(next: .swipeScrub(chrome: false), event: .swipeHorizontal(deltaProgress: 0.1), expected: .drop),
    .init(next: .swipeScrub(chrome: true), event: .swipeHorizontal(deltaProgress: 0.1), expected: .drop),
    .init(next: .clickSeek, event: .click(.right), expected: .keep),
    .init(next: .fullHUD, event: .select, expected: .flush),
    .init(next: .fullHUD, event: .click(.left), expected: .keep),
    .init(next: .fullHUD, event: .click(.up), expected: .keep),
    .init(next: .fullHUD, event: .playPause, expected: .keep),
    .init(next: .floor, event: .menu, expected: .flush),
    .init(next: .floor, event: .idle, expected: .flush),
]

struct PlayerHUDReducerTests {
    // Incomplete media whose runtime never resolved: `CMTimeGetSeconds(.indefinite)` is NaN, so
    // `durationSeconds > 0` is false and there's no scrubbable timeline.
    private let indeterminate = ReduceContext(shownProgress: 0, durationSeconds: .nan)

    @Test("every deterministic (state, event) cell lands where the table says",
          arguments: transitionTable)
    fileprivate func transitions(_ row: Transition) {
        let (state, effects) = reduce(row.state, row.event, row.ctx)
        #expect(state == row.expected)
        #expect(effects == row.effects)
    }

    // MARK: indeterminate duration (incomplete media)

    @Test("indeterminate runtime: analog and click seeks are inert in every state",
          arguments: [PlayerHUDState.floor, .clickSeek, .fullHUD])
    func indeterminateRuntimeIgnoresSeeks(state: PlayerHUDState) {
        for event in [RemoteEvent.swipeHorizontal(deltaProgress: 0.1), .click(.left), .click(.right)] {
            let (next, effects) = reduce(state, event, indeterminate)
            #expect(next == state)
            #expect(effects.isEmpty)
        }
    }

    @Test("indeterminate: vertical / play-pause / menu stay live")
    func indeterminateNonScrubStillWorks() {
        #expect(reduce(.floor, .swipeVertical, indeterminate).0 == .fullHUD)
        #expect(reduce(.floor, .playPause, indeterminate).1 == [.togglePlayPause])
        #expect(reduce(.floor, .menu, indeterminate).1 == [.exit])
    }

    // MARK: scrub surfaces

    @Test("a vertical swipe opens the chrome from either floor surface and is inert under it")
    func verticalSwipeOpensTheChrome() {
        #expect(reduce(.floor, .swipeVertical, baseCtx) == (PlayerHUDState.fullHUD, []))
        #expect(reduce(.clickSeek, .swipeVertical, baseCtx) == (PlayerHUDState.fullHUD, []))
        #expect(reduce(.fullHUD, .swipeVertical, baseCtx) == (PlayerHUDState.fullHUD, []))
    }

    /// The rule the `.menu` cancel used to break, stated as a rule: a hold nothing releases is a
    /// frozen picture under a glyph that reads intent, and nothing self-heals it.
    @Test("every exit from a swipe scrub releases the hold", arguments: [false, true])
    func everySwipeExitReleasesTheHold(chrome: Bool) {
        let exits: [RemoteEvent] = [.select, .idle, .menu, .playPause, .swipeVertical, .click(.up), .click(.left)]
        for event in exits {
            let (next, effects) = reduce(.swipeScrub(chrome: chrome), event, baseCtx)
            #expect(effects.contains(.releaseHold), "\(event) left the picture frozen")
            if case .swipeScrub = next { Issue.record("\(event) did not leave the scrub") }
        }
    }

    @Test("a swipe delta clamps to the track", arguments: [(0.95, 0.2, 1.0), (0.05, -0.2, 0.0)])
    func swipeDeltaClamps(shown: Double, delta: Double, expected: Double) {
        let ctx = ReduceContext(shownProgress: shown, durationSeconds: referenceDuration)
        let (_, effects) = reduce(.swipeScrub(chrome: false), .swipeHorizontal(deltaProgress: delta), ctx)
        #expect(effects == [.preview(progress: expected)])
    }

    // MARK: view-side predicates

    @Test("each state mounts exactly the surfaces the table says", arguments: surfaceTable)
    fileprivate func surfaces(_ row: SurfaceRow) {
        #expect(row.state.chromeUp == row.chromeUp)
        #expect(row.state.isAnalogScrub == row.isAnalogScrub)
        #expect(row.state.dimsVideo == row.dimsVideo)
    }

    @Test("the lone floor bar mounts for the floor's scrub surfaces and for a landing seek",
          arguments: floorBarTable)
    fileprivate func floorBar(_ row: FloorBarRow) {
        #expect(row.state.showsFloorScrubBar(landing: row.landing, loading: row.loading) == row.shows)
    }

    @Test("the head springs for a step or a landing, never under a finger",
          arguments: surfaceTable, [false, true])
    fileprivate func discreteStepAnimation(_ row: SurfaceRow, flightAlive: Bool) {
        let expected = !row.state.isAnalogScrub && flightAlive
        #expect(row.state.animatesDiscreteStep(flightAlive: flightAlive) == expected)
    }

    /// Only the destination and the event decide: the pending step itself is what carries the
    /// accumulated target, so where it came from says nothing about what to do with it.
    @Test("a pending click step is dropped, flushed or kept by where the reducer went",
          arguments: clickStepTable)
    fileprivate func pendingClickStep(_ row: ClickStepRow) {
        #expect(PlayerHUDState.pendingClickStep(after: row.next, on: row.event) == row.expected)
    }
}
