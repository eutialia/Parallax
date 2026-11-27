import CoreMedia
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxPlayback

/// `SessionPhase` over generated runs of loads and beats. Each beat is stamped with the live
/// session, one a load already replaced, or the one the next load will open.
@Suite("SessionPhase — properties")
struct SessionPhaseProperties {
    private enum Event {
        case load
        case beat(age: Int, PlaybackState)
    }

    private static let ongoing: [PlaybackState] = [
        .idle, .loading, .ready(duration: .zero, tracks: .empty),
        .playing(position: .zero, duration: .zero, buffered: nil, provenance: .observed),
    ]
    private static let terminal: [PlaybackState] = [.ended, .failed(.assetNotPlayable), .failed(.networkStalled)]

    private static func events(using random: inout SplitMix) -> [Event] {
        (0..<Int.random(in: 0...40, using: &random)).map { _ in
            guard Int.random(in: 0..<6, using: &random) > 0 else { return .load }
            let states = Int.random(in: 0..<5, using: &random) == 0 ? terminal : ongoing
            return .beat(age: Int.random(in: -1...2, using: &random), states.randomElement(using: &random)!)
        }
    }

    @Test("only the live session publishes, its terminal beat ends it, and only the next load opens another")
    func onlyTheLiveSessionPublishes() {
        let seed = UInt64(0x7068_6173_6573)
        var random = SplitMix(seed: seed)
        for _ in 0..<500 {
            let events = Self.events(using: &random)
            var phase = SessionPhase.live(.none)
            var opened: [PlaybackSessionID] = [.none]
            var ended = false
            for (step, event) in events.enumerated() {
                let context = "seed \(seed), step \(step) of \(events)"
                switch event {
                case .load:
                    let next = phase.opening()
                    #expect(next == .live(next.id), "\(context)")
                    #expect(!opened.contains(next.id), "a load reopened \(next.id): \(context)")
                    opened.append(next.id)
                    (phase, ended) = (next, false)
                case .beat(let age, let state):
                    let live = opened[opened.count - 1]
                    let session = age < 0 ? live.next() : opened[max(opened.count - 1 - age, 0)]
                    let published = phase.publishing(state, from: session)
                    #expect((published != nil) == (session == live && !ended), "\(context)")
                    guard let published else { continue }
                    let ends = Self.terminal.contains { $0.sameCase(as: state) }
                    #expect(published == (ends ? .terminated(live) : phase), "\(context)")
                    (phase, ended) = (published, ends)
                }
            }
        }
    }
}

private extension PlaybackState {
    func sameCase(as other: PlaybackState) -> Bool {
        switch (self, other) {
        case (.ended, .ended): true
        case (.failed(let a), .failed(let b)): a == b
        default: false
        }
    }
}
