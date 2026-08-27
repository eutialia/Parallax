import CoreText
import Foundation
import os
import ParallaxCore
import ParallaxSubtitles

/// Makes the bundled Noto faces visible to CoreText for this process.
///
/// Our own libass never needs this — it runs with `ASS_FONTPROVIDER_NONE` and is handed
/// the files directly. **libvlc's** text renderer does: on Darwin its font backend
/// resolves `:freetype-font=<family>` by asking CoreText for the family, and a file that
/// merely sits in the app bundle is not a family CoreText knows. Without this
/// registration `:freetype-font=Noto Sans` silently falls back to a system face —
/// which is exactly the device-dependent fallback the bundled fonts exist to avoid.
///
/// `.process` scope, so nothing is installed for other apps or persisted.
enum SubtitleFontRegistration {

    /// Every font file shipped in `ParallaxSubtitles`' fonts directory — the same list
    /// our own libass registers, read from the directory rather than named, so adding a
    /// face is a resource change only.
    static var fontFileURLs: [URL] { SubtitleFontBundle.fileURLs }

    /// Register every bundled file, once per process. Idempotent by construction:
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
        // Not `allSatisfy`: that short-circuits, and one refused file would
        // leave every file after it unregistered — which is how `Noto Sans`
        // itself once stopped resolving because iOS already ships a Noto
        // Armenian.
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
        // libass never asks CoreText, and the only family VLC is pointed at is `Noto Sans`.
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
