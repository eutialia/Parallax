import SwiftUI
import CoreMedia
import ParallaxPlayback

/// Draws client-rendered subtitle cues over the video surface, synced to the engine
/// clock (`PlaybackEngine.currentTime`, so it works for AVKit and VLC alike).
///
/// Used whenever `PlayerViewModel.activeSubtitleCues` is non-empty:
/// - Transcode: the correctly-timed WebVTT sidecar instead of the in-manifest HLS
///   WebVTT, whose `X-TIMESTAMP-MAP` drifts on fMP4 segments (jellyfin/jellyfin#16647).
/// - Direct-play external subs: VLC's simple text renderer can't shape sidecar VTT on
///   iOS (HarfBuzz "Runs count 0"), so we fetch + render them here instead of slaving
///   them to the engine.
///
/// Embedded subs (rendered by the engine itself — AVKit legible / VLC libass) leave
/// `activeSubtitleCues` empty, so this overlay draws nothing for them.
struct SubtitleOverlayView: View {
    let vm: PlayerViewModel

    @State private var text: String?

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let text {
                Text(text)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.9), radius: 3, x: 0, y: 1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 48)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // Opt into full-bleed like the video host: PlayerView no longer applies a
        // blanket .ignoresSafeArea(), so without this the cues would float up by the
        // bottom safe-area inset instead of sitting just above the home indicator.
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task { await drive() }
    }

    /// Polls the engine clock ~15×/s and shows whichever cue(s) contain "now".
    /// 0.5s playback-state beats are far too coarse for sub-second cues, so we
    /// read `engine.currentTime` directly rather than going through the state stream.
    private func drive() async {
        while !Task.isCancelled {
            text = currentCueText()
            try? await Task.sleep(for: .milliseconds(66))
        }
    }

    private func currentCueText() -> String? {
        let cues = vm.activeSubtitleCues
        // `.invalid` is VLC's "clock not ready" signal (buffering/seek); skip so a transient
        // unknown time doesn't flash the 0:00 cue. AVKit always reports a valid time (0 at the
        // start), so a genuine 0:00 cue still shows.
        guard !cues.isEmpty, let now = vm.engine?.currentTime, now.isValid else { return nil }
        let active = cues.filter {
            CMTimeCompare(now, $0.start) >= 0 && CMTimeCompare(now, $0.end) < 0
        }
        guard !active.isEmpty else { return nil }
        return active.map(\.text).joined(separator: "\n")
    }
}
