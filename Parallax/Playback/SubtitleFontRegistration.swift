import CoreText
import Foundation
import os
import ParallaxCore
import ParallaxSubtitles

/// Makes the ONE family VLC's text renderer is pointed at visible to CoreText for this
/// process.
///
/// Our own libass never needs this — it runs with `ASS_FONTPROVIDER_NONE` and is handed
/// the files directly, and VLC's internal libass scans `ssa-fontsdir` itself. **VLC's
/// simple freetype renderer** does: on Darwin its font backend resolves
/// `--freetype-font=<family>` by asking CoreText, and a file that merely sits in the app
/// bundle is not a family CoreText knows. Without this registration the option silently
/// falls back to a system face — exactly the device-dependent fallback the bundled fonts
/// exist to avoid.
///
/// `.process` scope, so nothing is installed for other apps or persisted.
enum SubtitleFontRegistration {

    /// Only the files backing the family VLC is pointed at — the launch region's pan-CJK
    /// collections, one per design (`VLCSubtitleFonts.freetypeFamily`). Nothing else needs
    /// CoreText: our own libass is handed files directly, and VLC's internal libass scans
    /// `ssa-fontsdir` itself.
    ///
    /// Registering all 39 bundled files instead made iOS log a `GSFont: "…" already
    /// exists.` for every face it ships under the same PostScript name (several Noto
    /// scripts), and each of those is a face CoreText then resolves to ITS copy, not ours.
    static var fontFileURLs: [URL] {
        SubtitleFontBundle.table[.cjk(VLCSubtitleFonts.fallbackLanguage())]?.fileURLs ?? []
    }

    /// Register `fontFileURLs`, once per process. Idempotent by construction:
    /// the work is the initializer of a `static let`, so the runtime's one-time
    /// initialization does the deduplication and concurrent callers all get the same
    /// answer. Returns whether every file is now registered.
    @discardableResult
    static func registerIfNeeded() -> Bool { registrationSucceeded }

    private static let registrationSucceeded: Bool = register()

    private static func register() -> Bool {
        let urls = fontFileURLs
        guard !urls.isEmpty else {
            Log.playback.error("subtitle fonts: none found to register with CoreText")
            return false
        }
        // Not `allSatisfy`: that short-circuits, and one refused file would leave every
        // file after it unregistered.
        return urls.map(register(_:)).reduce(true) { $0 && $1 }
    }

    private static func register(_ url: URL) -> Bool {
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
        let cfError = error?.takeRetainedValue()
        let code = cfError.map { CFErrorGetCode($0) } ?? -1
        // Two refusals mean "the name already resolves", which is the outcome we wanted:
        // `alreadyRegistered` when something else in the process (a test host, a preview)
        // got there first, and `duplicatedName` when iOS itself ships a face under that
        // family — it does for several Noto scripts. Neither costs us anything: our own
        // libass never asks CoreText, and the families VLC is pointed at are the pan-CJK
        // ones (`VLCSubtitleFonts.freetypeFamily`), which iOS does not ship.
        if code == CTFontManagerError.alreadyRegistered.rawValue
            || code == CTFontManagerError.duplicatedName.rawValue { return true }
        Log.playback.error(
            """
            subtitle fonts: CoreText refused \(url.lastPathComponent, privacy: .public) \
            (CTFontManagerError \(code, privacy: .public))
            """
        )
        return false
    }
}
