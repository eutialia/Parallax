import SwiftUI

/// A single glass pill holding the AirPlay + PiP glyphs, docked at the trailing end of
/// the bottom control row on iPad AND iPhone — the HIG puts AirPlay in a custom
/// player's lower-right corner (iOS 16+), and the tvOS system player keeps these
/// accessories on the transport bar's trailing side. One continuous surface, no
/// divider, like the TV app's accessory pill: glyphs float in shared air (centered in
/// equal segments, so the middle gap is 2× the end padding — ends tight, middle
/// generous). The AirPlay glyph is OUR symbol with an invisible `AVRoutePickerView`
/// on top for the tap (see `AirPlayRouteButton.hidesSystemGlyph`); the picker's own
/// chrome can't be size-matched to `pip.enter` and boxed the segment in. Either
/// segment is omitted if its capability is absent. Height matches `chipHeight` so the
/// pill rows with the chips.
struct PlayerSplitPill: View {
    let metrics: PlayerMetrics
    let airPlayAvailable: Bool
    let pipAvailable: Bool
    let onPiP: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if airPlayAvailable {
                ZStack {
                    Image(systemName: "airplay.video")
                        .font(.system(size: metrics.splitPillIcon, weight: .semibold))
                        .foregroundStyle(.white)
                        .accessibilityHidden(true)   // the picker carries the a11y element
                    AirPlayRouteButton(hidesSystemGlyph: true)
                }
                .frame(width: metrics.splitPillSegment, height: metrics.splitPillHeight)
                #if !os(tvOS)
                .hoverEffect(.highlight)
                #endif
            }
            if pipAvailable {
                Button(action: onPiP) {
                    Image(systemName: "pip.enter")
                        .font(.system(size: metrics.splitPillIcon, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: metrics.splitPillSegment, height: metrics.splitPillHeight)
                        .contentShape(Rectangle())
                }
                .tvChipButton()
                #if !os(tvOS)
                .hoverEffect(.highlight)
                #endif
                .accessibilityLabel("Picture in Picture")
            }
        }
        .playerGlassSurface(in: Capsule())
        .clipShape(Capsule())
    }
}

#Preview {
    ZStack {
        LinearGradient(colors: [.teal, .black], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        PlayerSplitPill(metrics: .tv, airPlayAvailable: true, pipAvailable: true) {}
    }
    .frame(width: 400, height: 220)
    .environment(\.colorScheme, .dark)
}

// (A one-shot "Chip chrome bisect" preview lived here during the rim investigation;
// it was retired once the chip adopted glass-outside-Button — its replica rows were
// frozen copies of the chip's internals, and its own comment warned the stacked
// variants were backdrop-confounded. The row-parity preview below is the keeper.)

// Diagnostic: the pill shares the bottom control row with the chips, so the two must
// row — same height (chipHeight == splitPillHeight), baseline-level glyphs, one gap
// rhythm. A height mismatch here means one of the paired metrics drifted.
#Preview("Chip + pill row parity") {
    ZStack {
        LinearGradient(colors: [.teal, .black], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        HStack(spacing: PlayerMetrics.tv.chipsGap) {
            PlayerGlassChip(systemImage: "waveform", label: "English", sub: "5.1",
                            metrics: .tv, accessibilityLabel: "Audio") {}
            PlayerSplitPill(metrics: .tv, airPlayAvailable: true, pipAvailable: true) {}
        }
    }
    .frame(width: 820, height: 260)
    .environment(\.colorScheme, .dark)
}
