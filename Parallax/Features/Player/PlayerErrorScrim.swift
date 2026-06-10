import SwiftUI

/// The player's explicit failure scrim — the loud half of the design's "failures
/// are loud, fallbacks are silent". One layout for both flavors: an audio-switch
/// failure (playback already fell back to the previous track and continues
/// underneath; retry / keep) and a fatal playback failure (retry / copy details /
/// close, with the raw error in a monospace block for support). The dim never
/// intercepts touches, so live chrome underneath stays usable in the non-fatal
/// flavor; only the centred content takes hits.
///
/// Buttons are supplied by the owner (they differ per flavor and platform) and
/// should use the native Liquid Glass styles: `.glassProminent` + white tint for
/// the primary action, `.glass` for the rest.
///
/// App target only: pure SwiftUI, no platform conditionals.
struct PlayerErrorScrim<Buttons: View>: View {
    var title: String
    var message: String
    /// Raw diagnostics for the monospace support block (fatal flavor only).
    var details: String? = nil
    var metrics: PlayerMetrics
    @ViewBuilder var buttons: Buttons

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = false

    var body: some View {
        ZStack {
            PlayerScrimStyle.dim(PlayerScrimStyle.errorDim)
            content
                .opacity(entered ? 1 : 0)
                .offset(y: entered ? 0 : PlayerScrimStyle.riseOffset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : PlayerScrimStyle.rise) { entered = true }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            column
                .frame(maxWidth: metrics.errorBodyMaxWidth)
            // Outside the body column's max-width so the row never compresses the
            // buttons into wrapping; it sizes to its natural width.
            HStack(spacing: metrics.errorButtonGap) {
                buttons
            }
            .font(.system(size: metrics.errorButtonSize, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.top, metrics.errorButtonsTop)
        }
        .multilineTextAlignment(.center)
        .padding(Space.s26)
    }

    private var column: some View {
        VStack(spacing: 0) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: metrics.errorGlyphSize, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: metrics.errorChipSize, height: metrics.errorChipSize)
                .glassEffect(.regular, in: Circle())
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: metrics.errorTitleSize, weight: .bold))
                .foregroundStyle(.white)
                .padding(.top, metrics.errorTitleTop)
            Text(message)
                .font(.system(size: metrics.errorBodySize))
                .foregroundStyle(.white.opacity(0.7))
                .lineSpacing(metrics.errorBodySize * 0.3)
                .padding(.top, metrics.errorBodyTop)
            if let details {
                Text(details)
                    .font(.system(size: metrics.errorDetailSize, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineSpacing(metrics.errorDetailSize * 0.5)
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
                    .padding(.horizontal, metrics.errorDetailPadX)
                    .padding(.vertical, metrics.errorDetailPadY)
                    .background(.white.opacity(0.05), in: detailShape)
                    .overlay(detailShape.strokeBorder(.white.opacity(0.1), lineWidth: 1))
                    .frame(maxWidth: metrics.errorDetailMaxWidth)
                    .padding(.top, metrics.errorDetailTop)
            }
        }
    }

    private var detailShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: metrics.errorDetailRadius, style: .continuous)
    }
}

#Preview("Playback stopped") {
    ZStack {
        Color.black.ignoresSafeArea()
        PlayerErrorScrim(
            title: "Playback stopped",
            message: "Couldn't decode that file.",
            details: "playback: decodeFailed\nffmpeg: hevc — concealing errors in frame 18342",
            metrics: PlayerMetrics(width: 1280)
        ) {
            Button("Try again", systemImage: "arrow.clockwise") {}
                .buttonStyle(.glassProminent)
                .tint(.white)
            Button("Copy details") {}
                .buttonStyle(.glass)
            Button("Close") {}
                .buttonStyle(.glass)
        }
    }
    .frame(width: 1280, height: 720)
    .environment(\.colorScheme, .dark)
}

#Preview("Couldn't switch audio") {
    ZStack {
        Color(red: 0.05, green: 0.05, blue: 0.06).ignoresSafeArea()
        PlayerErrorScrim(
            title: "Couldn't switch audio",
            message: "The English · 5.1 source didn't respond. Playback stayed on English · Stereo — nothing was lost.",
            metrics: PlayerMetrics(width: 1280)
        ) {
            Button("Try again", systemImage: "arrow.clockwise") {}
                .buttonStyle(.glassProminent)
                .tint(.white)
            Button("Keep current track") {}
                .buttonStyle(.glass)
        }
    }
    .frame(width: 1280, height: 720)
    .environment(\.colorScheme, .dark)
}
