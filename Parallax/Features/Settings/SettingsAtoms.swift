import SwiftUI

/// The "Soon" placeholder badge on a disabled Playback row (handoff `.soon`): a small hairline-bordered
/// pill. One spelling app-wide per the parity rules — always "Soon", never "Coming Soon".
struct SoonBadge: View {
    var body: some View {
        Text("Soon")
            .font(.soonBadge)
            .foregroundStyle(Color.tertiaryLabel)
            .padding(.horizontal, Space.s8)
            .padding(.vertical, 3)
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.separator, lineWidth: 1)
            )
            .accessibilityLabel("Coming soon")
    }
}

/// The leading selection circle on a library/folder picker row (handoff `.selc`). Three states:
/// `off` (empty ring), `on` (filled disc + check — this path becomes a library), and `mixed` (filled
/// disc + dash — a parent some of whose children are chosen). Filled with `Color.buttonFill` so it
/// reads as the same espresso/white "selected" token the primary button uses.
struct SelectionCircle: View {
    enum SelectionState: Equatable { case off, on, mixed }

    let state: SelectionState
    var size: CGFloat = 25

    private var lineWidth: CGFloat { size * 0.1 }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(state == .off ? Color.tertiaryLabel : Color.clear, lineWidth: lineWidth)
            Circle()
                .fill(state == .off ? Color.clear : Color.buttonFill)
            glyph
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.12), value: state)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        switch state {
        case .off:
            EmptyView()
        case .on:
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(Color.buttonLabel)
        case .mixed:
            // A dash (indeterminate) — a rounded bar, not a check.
            RoundedRectangle(cornerRadius: lineWidth, style: .continuous)
                .fill(Color.buttonLabel)
                .frame(width: size * 0.42, height: lineWidth)
        }
    }
}

/// A status pill — the server-detail "Connected" LED chip and the tvOS header version pill (handoff
/// `.statuspill` / `.tv-idhead .pill`). A leading dot-LED or SF Symbol, then a label, on a soft `fill`
/// capsule.
struct StatusPill: View {
    enum Lead: Equatable {
        /// A coloured status LED (e.g. `Color.ok` for Connected).
        case led(Color)
        /// A small SF Symbol (e.g. `info.circle` for the version pill).
        case symbol(String)
    }

    let lead: Lead
    let text: String

    var body: some View {
        HStack(spacing: Space.s8) {
            switch lead {
            case .led(let color):
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
            case .symbol(let name):
                Image(systemName: name)
                    .font(.rowSubtitle)
                    .foregroundStyle(Color.secondaryLabel)
            }
            Text(text)
                .font(.statusPill)
                .foregroundStyle(Color.secondaryLabel)
        }
        .padding(.horizontal, Space.s12)
        .padding(.vertical, Space.s8)
        .background(Color.fill, in: Capsule(style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// One status chip's data, for an identity hero's pill row.
struct StatusPillData: Identifiable {
    let lead: StatusPill.Lead
    let text: String
    var id: String { text }
}

/// The centered identity header atop a server-detail screen (handoff `.dhead` / `.tv-idhead`): the
/// source glyph, its name, a meta line, and a row of status chips. iOS draws a bare glyph; tvOS sets it
/// in a filled surface tile. The status `pills` — connection state + version (Jellyfin) or account (SMB)
/// — render the SAME on every platform: separate chips, not a single combined pill.
struct ServerIdentityHero: View {
    var systemImage: String? = nil
    /// A template image asset for the glyph, used in place of an SF Symbol when set (tinted like the
    /// symbol — a monochrome template, e.g. `JellyfinGlyph`). Drawn smaller than the symbol point size
    /// on each platform: the asset fills its frame, an SF Symbol only inks ~⅞ of its em box, so the
    /// matched-by-eye frame is ~0.88× the symbol size — render-calibrated against the sibling SMB hero's
    /// `externaldrive.badge.wifi` (28 vs the iOS 32; 35 vs the tvOS tile's 40).
    var image: String? = nil
    let name: String
    let meta: String
    /// Header status chips — the connection LED plus the version (Jellyfin) or account (SMB) badge.
    /// Separate pills, identical on iOS / iPadOS / tvOS (handoff `.tv-idhead .pills`).
    var pills: [StatusPillData] = []

    var body: some View {
        VStack(spacing: heroSpacing) {
            #if os(tvOS)
            IconTile(systemImage: systemImage, image: image, size: 76, cornerRadius: 20,
                     glyphSize: image == nil ? 40 : 35, fill: Color.surface, foreground: Color.label)
            #else
            if let image {
                Image(image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .foregroundStyle(Color.label)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(Color.label)
            }
            #endif
            VStack(spacing: 4) {
                Text(name)
                    .font(.cardHeaderTitle)
                    .foregroundStyle(Color.label)
                    .lineLimit(1)
                Text(meta)
                    .font(.cardHeaderSubtitle)
                    .foregroundStyle(Color.secondaryLabel)
                    .lineLimit(1)
            }
            HStack(spacing: Space.s12) {
                // Keyed by position, not StatusPillData.id (== text): two pills with the same text
                // (e.g. an SMB account that happens to read "Connected") would collide and drop a chip.
                ForEach(Array(pills.enumerated()), id: \.offset) { _, pill in
                    StatusPill(lead: pill.lead, text: pill.text)
                }
            }
            .padding(.top, Space.s3)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, Space.s8)
    }

    private var heroSpacing: CGFloat {
        #if os(tvOS)
        Space.s14
        #else
        Space.s8
        #endif
    }
}

/// The centered intro lockup for a task screen (handoff `.intro` / `.formhead`): the app icon (or a
/// glyph) over a title and a one-line explainer. Used by the Add-Server "choose type" step and the
/// sign-in forms' headers.
struct FormIntroHeader: View {
    var glyph: BrandTile.Glyph = .brandIcon
    let title: String
    var subtitle: String? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: Space.s14) {
            BrandTile(glyph: glyph, size: 64, colorScheme: colorScheme)
                .equatable()
            VStack(spacing: 4) {
                Text(title)
                    .scaledFont(24, relativeTo: .title2, weight: .bold)
                    .foregroundStyle(Color.label)
                if let subtitle {
                    Text(subtitle)
                        .font(.authSubtitle)
                        .foregroundStyle(Color.secondaryLabel)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// An inline load-failure card: a centered message over a glass Retry button. Shared by the Visible
/// Libraries picker and the SMB folder picker so their identical error states can't drift apart.
struct SettingsRetryError: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: Space.s12) {
            Text(message)
                .font(.callout)
                .foregroundStyle(Color.secondaryLabel)
                .multilineTextAlignment(.center)
            Button("Retry", action: onRetry)
                .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity)
        .padding(Space.s30)
    }
}

extension Font {
    /// The "Soon" badge / status-pill label: small and quiet. iOS keeps the handoff's ~11–13pt; tvOS
    /// nudges to a fixed 18pt — a decorative chip, so it sits below the 23pt body floor without hurting
    /// legibility of actual content.
    static var soonBadge: Font {
        #if os(tvOS)
        .system(size: 18, weight: .semibold)
        #else
        .caption2.weight(.semibold)
        #endif
    }

    /// The server-detail status / version pill label.
    static var statusPill: Font {
        #if os(tvOS)
        .system(size: 20, weight: .semibold)
        #else
        .footnote.weight(.semibold)
        #endif
    }
}
