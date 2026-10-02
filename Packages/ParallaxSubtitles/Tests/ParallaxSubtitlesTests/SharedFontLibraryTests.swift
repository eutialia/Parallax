import CoreGraphics
import Foundation
import Testing

@testable import ParallaxSubtitles

/// The bundled files are ~50 MB and `ass_add_font` memcpy's them into the
/// `ASS_Library`. One library per `SubtitleRenderer` therefore charged every
/// subtitle pick a ~50 MB copy plus a re-parse of fifty faces — user-visible
/// latency on a mid-playback track switch. These tests pin the two properties
/// that removing it depends on: registration happens once, and the single
/// shared library keeps concurrent renderers from bleeding into each other.
@Suite("Shared libass library")
struct SharedFontLibraryTests {

    /// Two live renderers is the shipping configuration: the player overlay and
    /// the settings live preview. They now share one `ASS_Library`, whose message
    /// callback is per LIBRARY — so this is the test that the per-renderer
    /// `diagnosticLog` survived the sharing. Each task loads scripts that resolve
    /// to a different collection; a log carrying the other's family means the
    /// routing broke.
    @Test("two renderers rendering at once keep their own font logs")
    func concurrentRenderersKeepSeparateLogs() async throws {
        let sans = await makeProbeRenderer()
        let serif = await makeProbeRenderer()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await Self.render(on: sans, authoredFont: "Arial") }
            group.addTask { await Self.render(on: serif, authoredFont: "MS Mincho") }
        }

        let sansLog = fontSelectLines(await sans.diagnosticLog)
        let serifLog = fontSelectLines(await serif.diagnosticLog)

        #expect(!sansLog.isEmpty)
        #expect(!serifLog.isEmpty)
        #expect(sansLog.contains { $0.contains("NotoSansCJK") })
        #expect(!sansLog.contains { $0.contains("NotoSerifCJK") })
        #expect(serifLog.contains { $0.contains("NotoSerifCJK") })
        #expect(!serifLog.contains { $0.contains("NotoSansCJK") })

        #expect(!(await sans.diagnosticLog).contains { $0.contains("failed to find any fallback") })
        #expect(!(await serif.diagnosticLog).contains { $0.contains("failed to find any fallback") })
    }

    // MARK: - Embedded fonts

    /// A shared library would be a real leak if a script's `[Fonts]`
    /// attachments reached it: `ass_add_font` appends to `library->fontdata`,
    /// nothing frees it while the library lives, and every later renderer's
    /// `fontselect` would see the attachment.
    ///
    /// It cannot happen, and the reason is structural rather than behavioural:
    /// libass 0.17.5's `decode_font` (ass.c) only calls `ass_add_font` when
    /// `library->extract_fonts` is set, `ass_library_init` callocs that flag to
    /// zero, and `ass_set_extract_fonts` is called from nowhere in this package.
    /// What can be observed from here is the consequence — a carrier script's
    /// attachment section adds nothing to what we registered, and no renderer
    /// ever resolves to a face that is not one of ours. Feeding libass a fake
    /// payload proves nothing either way (it cannot decode one), so it is not
    /// attempted.
    @Test("a script's embedded fonts never reach a later renderer")
    func embeddedFontsStayOutOfTheSharedLibrary() async throws {
        let embeddedFamily = "ParallaxEmbeddedProbe"
        let carrier = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 640
        PlayResY: 360

        [Fonts]
        fontname: \(embeddedFamily)_0.ttf

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,\(embeddedFamily),28,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,2,20,20,20,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,Embedded

        """

        let before = LibassLibrary.shared.registeredFileNames
        let carrierRenderer = await makeProbeRenderer()
        try await carrierRenderer.load(Data(carrier.utf8), format: .ass)
        _ = await carrierRenderer.frame(at: 2.0)
        // Nothing but bundle files is ever registered, attachment or not.
        let added = LibassLibrary.shared.registeredFileNames.subtracting(before)
        #expect(added.isSubset(of: Set(SubtitleFontBundle.fileURLs.map(\.lastPathComponent))),
                "\(added)")

        let later = await makeProbeRenderer()
        try await later.load(ASSFixture.data(text: "字幕", fontName: "Arial"), format: .ass)
        _ = try #require(await later.frame(at: 2.0))

        for log in [await carrierRenderer.diagnosticLog, await later.diagnosticLog] {
            let selections = fontSelectLines(log)
            #expect(!selections.isEmpty)
            #expect(!selections.contains { $0.contains(embeddedFamily) })
            // Every resolution lands in a face we ship; libass names the file
            // it chose by its PostScript name, and all of ours are `Noto*`.
            #expect(selections.allSatisfy { $0.contains("-> Noto") }, "\(selections)")
        }
    }

    // MARK: - Lazy registration

    /// `ass_add_font` memcpy's into a library that is never torn down, so what a
    /// track does NOT need must never be registered: the two pan-CJK
    /// collections alone are 45 MB of permanently resident memory.
    ///
    /// Asserted as "a CJK track puts the collection in the library, and a second
    /// one leaves it there exactly once". Suites run in parallel against one
    /// process-wide library, so NOTHING about the whole registered set is a
    /// claim a single test can make: neither "only the Latin faces are there"
    /// nor "the set is unchanged" — another suite's track can register a face
    /// between the two reads and make an equality fail with nothing wrong. What
    /// survives that is per-file: the collection this test loads is present.
    /// The English-only half is pinned on the pure mapping instead
    /// (`SubtitleFontPlanTests.filesFollowTheFamilies`).
    @Test("a CJK track registers the collection")
    func cjkTrackRegistersTheCollection() async throws {
        let chinese = await makeProbeRenderer()
        try await chinese.load(
            SRTFixture.data(text: "简体字幕测试"), format: .srt, languageHint: "zh-Hans"
        )
        _ = try #require(await chinese.frame(at: 2.0))
        #expect(LibassLibrary.shared.registeredFileNames.contains("NotoSansCJK-Regular.ttc"))

        let again = await makeProbeRenderer()
        try await again.load(
            SRTFixture.data(text: "简体字幕测试"), format: .srt, languageHint: "zh-Hans"
        )
        _ = try #require(await again.frame(at: 2.0))
        // The library keys registrations by file name (a Set), so "once" is
        // structural; what the second load can prove is that the collection is
        // still there and that the renderer picked it up below.
        #expect(LibassLibrary.shared.registeredFileNames.contains("NotoSansCJK-Regular.ttc"))

        // The point of it all: the second track still resolved to the face,
        // which means the renderer re-ran ass_set_fonts after the library grew.
        #expect(selected("Noto Sans CJK SC", in: await again.diagnosticLog))
        #expect(!(await again.diagnosticLog).contains { $0.contains("Using default font") })
    }

    /// Track loads and frame renders, interleaved, so the two tasks overlap on
    /// the shared library rather than on one renderer's private state —
    /// `ass_read_memory` is the call that writes to the library.
    private static func render(on renderer: SubtitleRenderer, authoredFont: String) async {
        for index in 0..<20 {
            let data = ASSFixture.data(text: "字幕測試 \(index)", fontName: authoredFont)
            try? await renderer.load(data, format: .ass)
            _ = await renderer.frame(at: 2.0)
            await Task.yield()
        }
    }
}
