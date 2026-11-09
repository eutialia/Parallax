import ParallaxFileBrowseTestSupport
@testable import ParallaxFeatures
import ParallaxTestScaling
import Testing

@MainActor
@Suite("Thumbnail cache card", .scaledTimeLimit())
struct ThumbnailCacheModelTests {
    @Test("a size read that lands after a clear leaves the card showing Empty")
    func lateSizeReadAfterClearStaysEmpty() async {
        let sizeRead = AsyncGate(open: false)
        let cache = ThumbnailCacheModel(size: { await sizeRead.pass(); return 4_096_000 }, clear: {})
        let measuring = Task { await cache.measure() }
        await sizeRead.awaitArrivals()

        await cache.clear()
        await sizeRead.open()
        await measuring.value

        #expect(cache.sizeLabel == "Empty")
    }

    @Test("a second Clear while the first is still clearing wipes the cache once")
    func overlappingClearsWipeOnce() async {
        let wipe = AsyncGate(open: false)
        let cache = ThumbnailCacheModel(size: { 4_096_000 }, clear: { await wipe.pass() })
        let first = Task { await cache.clear() }
        await wipe.awaitArrivals()
        #expect(cache.sizeLabel == "Clearing…")

        let second = Task { await cache.clear() }
        await wipe.open()
        await first.value
        await second.value

        #expect(await wipe.arrivalCount == 1)
        #expect(cache.sizeLabel == "Empty")
    }
}
