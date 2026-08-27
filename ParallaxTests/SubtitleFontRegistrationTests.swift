import CoreText
import Foundation
import Testing
@testable import Parallax
import ParallaxSubtitles

/// libvlc's Darwin text renderer resolves `:freetype-font=<family>` by asking CoreText for
/// the family — so a bundled file nothing registered is a family that does not exist, and
/// the option silently falls back to a system face. That is the exact device-dependent
/// fallback the bundled fonts were shipped to eliminate.
///
/// App-hosted on purpose: the fonts live in `ParallaxSubtitles`' resource bundle, which only
/// resolves inside a real app bundle.
@Suite("SubtitleFontRegistration")
struct SubtitleFontRegistrationTests {

    /// Every file the package ships, not a hand-kept list: the two lists coming
    /// apart is how a face ends up drawable by our libass and invisible to VLC's.
    @Test("every file the package ships is what gets registered")
    func registersEveryBundledFile() {
        let names = SubtitleFontRegistration.fontFileURLs.map(\.lastPathComponent)
        #expect(names == SubtitleFontBundle.fileURLs.map(\.lastPathComponent))
        #expect(names.contains("NotoSans-Regular.ttf"))
        #expect(names.contains("NotoSansCJK-Regular.ttc"))
        #expect(names.contains("NotoNaskhArabic-Regular.ttf"))
        // Derived from the routing table, never a hand-kept count: a script added to
        // the bundle updates both sides at once. A file in the directory no table row
        // names is drawable by our libass and unreachable by family, which is the
        // exact drift this suite exists to catch.
        #expect(Set(names) == Set(SubtitleFontBundle.table.values.flatMap(\.fileNames)))
        #expect(names.allSatisfy { $0.hasPrefix("Noto") })
    }

    /// The whole point: `CTFontCreateWithName` silently substitutes a system face for a name
    /// it cannot resolve, so an unregistered family fails this by coming back as something
    /// else entirely rather than by erroring.
    @Test("CoreText resolves the bundled families after registration", arguments: [
        SubtitleFontBundle.sansFamily,
        SubtitleFontBundle.serifFamily,
        SubtitleFontBundle.family(design: .sans, language: .japanese),
        SubtitleFontBundle.family(design: .serif, script: .thai),
        SubtitleFontBundle.family(design: .sans, script: .arabic),
    ])
    func coreTextResolvesTheFamily(family: String) {
        #expect(SubtitleFontRegistration.registerIfNeeded())

        let font = CTFontCreateWithName(family as CFString, 24, nil)
        #expect(CTFontCopyFamilyName(font) as String == family)
    }

    /// Registration runs once and every later call reads the memo — it rides the app's launch
    /// path, so a second call must not re-do ~50 MB of file work.
    @Test("registering again is free and still true")
    func registrationIsIdempotent() {
        #expect(SubtitleFontRegistration.registerIfNeeded())
        #expect(SubtitleFontRegistration.registerIfNeeded())
    }
}
