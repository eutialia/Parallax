import Testing
import ParallaxPlayback

/// `PlaybackDebugInfo.empty` is the value the HUD falls back to whenever an engine can't
/// report — every field must be genuinely absent, or the HUD prints a fabricated number
/// (a zero bitrate reads very differently from "—").
@Suite("PlaybackDebugInfo.empty")
struct PlaybackDebugInfoTests {

    @Test("every optional field is nil")
    func optionalsAreNil() {
        let info = PlaybackDebugInfo.empty
        #expect(info.presentationWidth == nil)
        #expect(info.presentationHeight == nil)
        #expect(info.renderedFrameRate == nil)
        #expect(info.indicatedBitrate == nil)
        #expect(info.observedBitrate == nil)
        #expect(info.droppedVideoFrames == nil)
        #expect(info.bufferedSeconds == nil)
        #expect(info.playheadSeconds == nil)
        #expect(info.itemStatus == nil)
        #expect(info.selectedAudible == nil)
        #expect(info.selectedLegible == nil)
        #expect(info.transportState == nil)
        #expect(info.stallCount == nil)
        #expect(info.bytesTransferred == nil)
    }

    @Test("every list field is empty")
    func listsAreEmpty() {
        let info = PlaybackDebugInfo.empty
        #expect(info.loadedRanges.isEmpty)
        #expect(info.legibleOptions.isEmpty)
        #expect(info.errorLogTail.isEmpty)
        #expect(info.accessLogTail.isEmpty)
    }
}
