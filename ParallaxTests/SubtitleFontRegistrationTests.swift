import CoreText
import Foundation
import Testing
@testable import Parallax
import ParallaxSubtitles

/// libvlc's Darwin text renderer resolves `--freetype-font=<family>` by asking CoreText for
/// the family — so the family VLC is pointed at must be one CoreText knows, or the option
/// silently falls back to a system face. That is the exact device-dependent fallback the
/// bundled fonts were shipped to eliminate.
///
/// Nothing else is registered: our own libass is handed files directly, and VLC's internal
/// libass scans `ssa-fontsdir` itself. Registering the whole bundle instead made iOS refuse
/// the faces it already ships under the same PostScript name — a duplicate CoreText then
/// resolves to ITS copy, not ours.
///
/// App-hosted on purpose: the fonts live in `ParallaxSubtitles`' resource bundle, which only
/// resolves inside a real app bundle.
@Suite("SubtitleFontRegistration")
struct SubtitleFontRegistrationTests {

    /// Derived from the routing table, never a hand-kept list: what gets registered and what
    /// VLC is told to ask for have to come from the same row, or the option names a family
    /// that does not exist.
    @Test("exactly the files backing the family VLC asks for are registered")
    func registersTheFamilyVLCAsksFor() {
        let names = SubtitleFontRegistration.fontFileURLs.map(\.lastPathComponent)
        let region = VLCSubtitleFonts.fallbackLanguage()

        #expect(Set(names) == Set(SubtitleFontBundle.table[.cjk(region)]?.fileNames ?? []))
        // One collection per design — the design can change between sessions without a
        // relaunch, and the family is fixed when the player is built.
        #expect(names.count == 2)
        #expect(names.allSatisfy { $0.hasSuffix(".ttc") })
        // The Latin-only faces are deliberately absent: they cover no Han, which is the
        // whole reason the freetype family is a pan-CJK one.
        #expect(names.contains("NotoSans-Regular.ttf") == false)
    }

    /// The whole point: `CTFontCreateWithName` silently substitutes a system face for a name
    /// it cannot resolve, so an unregistered family fails this by coming back as something
    /// else entirely rather than by erroring.
    @Test("CoreText resolves the freetype family in both designs",
          arguments: SubtitleFontBundle.Design.allCases)
    func coreTextResolvesTheFreetypeFamily(design: SubtitleFontBundle.Design) {
        #expect(SubtitleFontRegistration.registerIfNeeded())

        let family = VLCSubtitleFonts.freetypeFamily(for: design)
        let font = CTFontCreateWithName(family as CFString, 24, nil)
        #expect(CTFontCopyFamilyName(font) as String == family)
    }

    /// Registration runs once and every later call reads the memo — it rides the app's launch
    /// path, so a second call must not re-do the file work.
    @Test("registering again is free and still true")
    func registrationIsIdempotent() {
        #expect(SubtitleFontRegistration.registerIfNeeded())
        #expect(SubtitleFontRegistration.registerIfNeeded())
    }
}
