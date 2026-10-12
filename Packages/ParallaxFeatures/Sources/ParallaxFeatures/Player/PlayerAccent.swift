import Foundation
import Observation
import ParallaxCore

/// The playing item's artwork hue: the colour the scrub bar paints its provisional elements in.
@Observable
@MainActor
final class PlayerAccent {
    /// The hue, once it has been derived. Nil is the answer for the whole first second of every
    /// session, for artwork with no usable colour, for SMB (no `ItemDetail`, no image ref), and
    /// for any failure along the way; nil means the bar stays its monochrome white, which is the
    /// pre-accent look.
    private(set) var hsb: AccentHSB?
    /// The one-shot derivation, held only so a new item (or `stop()`) can cancel a fetch that
    /// is still in flight and can't be allowed to paint the next item's bar.
    @ObservationIgnored private var task: Task<Void, Never>?

    /// The playing item's artwork bytes, for the scrub bar's accent hue. A closure because the
    /// image lives behind a session-scoped image pipeline (auth header, shared disk cache) the
    /// player has no business knowing about; the default answers nil, which is the white
    /// bar. Bytes rather than a decoded image on purpose: `Data` crosses to the extraction's
    /// off-main task without an isolation argument, and the decode is part of the work we are
    /// moving off the main thread anyway.
    @ObservationIgnored private let fetchArtwork: @Sendable (ItemDetail) async -> Data?

    init(fetchArtwork: @escaping @Sendable (ItemDetail) async -> Data?) {
        self.fetchArtwork = fetchArtwork
    }

    isolated deinit {
        task?.cancel()
    }

    /// Derives the scrub bar's accent from the item's artwork, once per item, in the background.
    /// Reset to nil FIRST so an episode→episode swap can never show the previous poster's hue
    /// on the new item's bar, not even for the beat before the new fetch answers.
    ///
    /// Nothing here is allowed to matter: the fetch is best-effort, the decode runs off the main
    /// actor (a poster decode has no business on the main thread while a stream is opening), and
    /// every failure — no ref, no bytes, no colour in the artwork — leaves the bar white. It is
    /// deliberately NOT awaited anywhere in the start path.
    ///
    /// The decode is a `nonisolated` call, not a nested `Task.detached`: awaiting a detached
    /// task's `.value` is not a cancellation point, so a nested one outlived the item it was
    /// decoding for. A plain call inherits this task's cancellation and is one hop cheaper.
    func load(for item: ItemDetail) {
        task?.cancel()
        hsb = nil
        task = Task(priority: .utility) { [weak self, fetchArtwork] in
            guard let data = await fetchArtwork(item), !Task.isCancelled else { return }
            let accent = await Self.extractAccent(from: data)
            guard !Task.isCancelled else { return }
            self?.hsb = accent
        }
    }

    /// The decode + vote, off the main actor. `nonisolated` is the whole point: this type is
    /// `@MainActor`, and this is the one step that must not run there.
    private nonisolated static func extractAccent(from data: Data) async -> AccentHSB? {
        ArtworkAccent.accent(fromImageData: data)
    }

    /// The session is over: drop the hue and any fetch still deriving one.
    func reset() {
        task?.cancel()
        task = nil
        hsb = nil
    }
}
