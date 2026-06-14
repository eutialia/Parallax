import Testing
import Foundation
@testable import ParallaxCore

@Suite("ArtworkSource")
struct ArtworkSourceTests {
    @Test("cases are equatable by payload")
    func equality() {
        let url = URL(string: "file:///tmp/a.jpg")!
        #expect(ArtworkSource.local(url) == ArtworkSource.local(url))
        #expect(ArtworkSource.none != ArtworkSource.local(url))
        #expect(ArtworkSource.remote(url, headers: nil) == ArtworkSource.remote(url, headers: nil))
        #expect(ArtworkSource.remote(url, headers: ["A": "1"]) != ArtworkSource.remote(url, headers: nil))
    }
}
