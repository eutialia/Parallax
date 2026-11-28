import CoreGraphics
import Foundation
import ParallaxSubtitles
import Testing

/// The subtitle files under `Fixtures/`, as a server or a share would hand them over.
enum SubtitleFixtureFile: String {
    /// Two plain lines, at 1 s to 3 s and 5 s to 7 s.
    case twoLinesSRT = "two-lines.srt"
    case twoLinesVTT = "two-lines.vtt"
    /// The same two lines, authored yellow in the top-left corner of a 640x360 script.
    case yellowTopLeftASS = "yellow-top-left.ass"

    var data: Data {
        get throws {
            let url = try #require(Bundle.module.url(forResource: "Fixtures/\(rawValue)", withExtension: nil))
            return try Data(contentsOf: url)
        }
    }
}

/// The fetch edge of a `SubtitleDisplay`: answers each URL from a script, and keeps the URLs
/// asked for, in order.
final class ScriptedSubtitleFetch: Sendable {
    private let answer: @Sendable (URL) async -> SubtitleFetchOutcome
    private let log = Log()

    private actor Log {
        var urls: [URL] = []
        func add(_ url: URL) { urls.append(url) }
    }

    init(_ answer: @escaping @Sendable (URL) async -> SubtitleFetchOutcome) {
        self.answer = answer
    }

    var requested: [URL] { get async { await log.urls } }

    func fetch(_ url: URL) async -> SubtitleFetchOutcome {
        await log.add(url)
        return await answer(url)
    }
}

/// Holds a fetch's answer back until the test lets it go.
actor FetchGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func passed() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// What a `SubtitleDisplay` told its player, in order.
@MainActor
final class DisplayEvents {
    enum Event: Equatable {
        case landed(URL)
        case failed(URL)
    }

    private(set) var all: [Event] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(of display: SubtitleDisplay) {
        display.onLanded = { [weak self] in self?.record(.landed($0.url)) }
        display.onFailed = { [weak self] in self?.record(.failed($0.url)) }
    }

    private func record(_ event: Event) {
        all.append(event)
        waiters.forEach { $0.resume() }
        waiters = []
    }

    /// Returns once `count` events have arrived.
    func reach(_ count: Int) async {
        while all.count < count {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}

/// The near-opaque pixels of the frame `renderer` draws at `seconds`, on a 640x360 canvas.
func inkDrawn(by renderer: SubtitleRenderer, at seconds: Double) async throws -> (frame: SubtitleFrame, pixels: [RenderedPixels.Pixel]) {
    let size = CGSize(width: 640, height: 360)
    await renderer.setCanvas(size: size, scale: 1, storageSize: size)
    let frame = try #require(await renderer.frame(at: seconds))
    let image = try #require(frame.image, "nothing is drawn at \(seconds) s")
    return (frame, try rendered(image).opaque)
}
