import SwiftUI
import AVFoundation
import CoreMedia
import ParallaxPlayback

/// Draws client-rendered subtitle cues over the AVKit video surface.
///
/// On the transcode path we fetch the subtitle as a separately-delivered,
/// correctly-timed WebVTT sidecar (`PlayerViewModel.activeSubtitleCues`) instead
/// of the in-manifest HLS WebVTT, whose `X-TIMESTAMP-MAP` drifts on fMP4 segments
/// (jellyfin/jellyfin#16647). We bypass AVPlayer's own legible rendering for that
/// stream, so we paint the cues here, synced to the player clock.
///
/// AVKit-only by construction: VLC renders its own subtitles and its engine is
/// not an `AVPlayerHosting`, so the clock lookup returns nil and nothing is drawn
/// (and `activeSubtitleCues` is empty on that path anyway).
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

    /// Polls the player clock ~15×/s and shows whichever cue(s) contain "now".
    /// 0.5s playback-state beats are far too coarse for sub-second cues, so we
    /// read the AVPlayer clock directly rather than going through the engine's
    /// state stream.
    private func drive() async {
        while !Task.isCancelled {
            text = currentCueText()
            try? await Task.sleep(for: .milliseconds(66))
        }
    }

    private func currentCueText() -> String? {
        guard let hosting = vm.engine as? AVPlayerHosting else { return nil }
        let cues = vm.activeSubtitleCues
        guard !cues.isEmpty else { return nil }
        let now = hosting.avPlayer.currentTime()
        let active = cues.filter {
            CMTimeCompare(now, $0.start) >= 0 && CMTimeCompare(now, $0.end) < 0
        }
        guard !active.isEmpty else { return nil }
        return active.map(\.text).joined(separator: "\n")
    }
}
