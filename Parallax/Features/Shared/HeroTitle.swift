import SwiftUI
import ParallaxJellyfin
import ParallaxCore

/// Hero title treatment: text over `.primary` poster art (logo is often baked in),
/// transparent logo over landscape/backdrop art.
struct HeroTitle: View {
    enum Scale {
        case home
        case detail

        // tv sizes anchor the hero to the tvOS type ramp (HIG Title 1 = 76pt) — the 10-foot
        // canvas needs ~1.5× the iPad point size, same ramp the shelf headers adopted (audit C2).
        // iPad-sized hero type on tv was the audit's C1/C3 defect class, missed here.
        func pointSize(idiom: AppIdiom) -> CGFloat {
            switch self {
            case .home:
                switch idiom {
                case .compact: 32
                case .regular: 52
                case .tv: 76
                }
            case .detail:
                switch idiom {
                case .compact: 30
                case .regular: 48
                case .tv: 70
                }
            }
        }
    }

    /// Logo box height per idiom. The wordmark replaces the text title, so it keeps the title's
    /// established ~1.85× visual mass (60/32, 96/52) at each idiom's scale — tv = 76pt × 1.85.
    static func logoHeight(idiom: AppIdiom) -> CGFloat {
        switch idiom {
        case .compact: 60
        case .regular: 96
        case .tv: 140
        }
    }

    let title: String
    let logoRef: ImageRef?
    let session: Session
    let idiom: AppIdiom
    let usesLogo: Bool
    var scale: Scale = .home

    var body: some View {
        Group {
            if usesLogo, let logoRef {
                logo(logoRef)
            } else {
                textTitle
            }
        }
    }

    private var textTitle: some View {
        Text(title)
            .scaledFont(scale.pointSize(idiom: idiom), relativeTo: .largeTitle, weight: .heavy)
            .foregroundStyle(.white)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
    }

    private func logo(_ ref: ImageRef) -> some View {
        // Request ceiling = the column cap × 2x display scale: a wide logo filling the cap needs
        // that many pixels; the old flat 800 upscaled wide logos on iPad and tv alike.
        MediaImage(
            jellyfin: ref,
            session: session,
            maxWidth: Int(HeroMetrics.contentMaxWidth(idiom: idiom) * 2),
            style: .logo
        )
        .frame(height: Self.logoHeight(idiom: idiom), alignment: .leading)
        .frame(maxWidth: HeroMetrics.contentMaxWidth(idiom: idiom), alignment: .leading)
        .accessibilityLabel(title)
    }
}

extension HeroTitle {
    init(item: Item, session: Session, idiom: AppIdiom, scale: Scale = .home) {
        self.title = item.displayTitle
        self.logoRef = item.heroLogoRef
        self.session = session
        self.idiom = idiom
        self.usesLogo = item.heroUsesLogoTitle(regularWidth: idiom.usesLandscapeHeroBand)
        self.scale = scale
    }
}

// MARK: - Preview harness

/// Mock logo artwork standing in for a Jellyfin `.logo` image — a static render can't load
/// `MediaImage` over the network. Drawn on a fixed 340×100 design canvas (3.4:1, a typical
/// transparent-wordmark aspect), then scaled exactly like the real `.fit` path: height pinned
/// to `HeroTitle.logoHeight`'s box, width following the aspect, 720pt cap, leading-aligned.
private struct PreviewHeroLogo: View {
    let idiom: AppIdiom

    private static let designSize = CGSize(width: 340, height: 100)

    var body: some View {
        let height = HeroTitle.logoHeight(idiom: idiom)
        let scale = height / Self.designSize.height
        VStack(spacing: 4) {
            Text("ORBITAL")
                .font(.system(size: 62, weight: .black))
                .kerning(6)
            Text("DECAY")
                .font(.system(size: 24, weight: .medium))
                .kerning(14)
        }
        .foregroundStyle(.white)
        .frame(width: Self.designSize.width, height: Self.designSize.height)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: Self.designSize.width * scale, height: height, alignment: .topLeading)
        .frame(maxWidth: HeroMetrics.contentMaxWidth(idiom: idiom), alignment: .leading)
    }
}

/// Foreground column for the scale panels — `HeroForeground`'s skeleton with the logo mocked
/// and, because an iOS-destination render can't apply the tvOS Dynamic-Type ramp, the semantic
/// fonts pinned to their per-platform resolved sizes (caption 12→25, subheadline 15→29,
/// headline 17→38 — HIG tvOS table) and the pill to `ActionRow.controlHeight`'s device values.
private struct PreviewLogoForeground: View {
    @Environment(\.appIdiom) private var idiom

    var body: some View {
        let tv = idiom == .tv
        VStack(alignment: .leading, spacing: Space.s12) {
            Text("FEATURED")
                .font(.system(size: tv ? 25 : 12, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(.white)
                .padding(.horizontal, tv ? Space.s18 : Space.s12)
                .padding(.vertical, tv ? Space.s8 : Space.s3)
                .background(.black.opacity(0.5), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                .fixedSize(horizontal: false, vertical: true)
            PreviewHeroLogo(idiom: idiom)
            Text("A crew on humanity's last orbital station races to prevent a cascade failure before re-entry, rationing oxygen while the ground crew fights to reach them in time.")
                .font(.system(size: tv ? 29 : 15))
                .foregroundStyle(.white)
                .lineLimit(3)
                .frame(maxWidth: HeroMetrics.overviewMaxWidth(idiom: idiom), alignment: .leading)
            Label("Play", systemImage: "play.fill")
                .font(.system(size: tv ? 38 : 17, weight: .semibold))
                .foregroundStyle(Color.playerInk)
                .padding(.horizontal, Space.s22)
                .frame(height: tv ? 62 : 52)
                .background(.white, in: Capsule())
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.s8)
        }
        .frame(maxHeight: HeroMetrics.foregroundMaxHeight(idiom: idiom), alignment: .bottom)
    }
}

/// One mock screen at native point size, scaled to a shared display width so panels compare
/// like-for-like. `HeroBand` applies the real per-idiom foreground placement from the injected
/// `appIdiom`, so tvOS gets its true overscan insets and iPad its 16:9 band + shelf below.
private struct HeroLogoScalePanel: View {
    let caption: String
    let screen: CGSize
    let displayWidth: CGFloat
    let idiom: AppIdiom
    /// tvOS's hero fills the viewport (`tvHeroHeightFraction` = 1.0); iPad's is a 16:9 band.
    let bandFillsScreen: Bool

    var body: some View {
        let scale = displayWidth / screen.width
        VStack(alignment: .leading, spacing: Space.s8) {
            Text(caption)
                .font(.headline)
                .foregroundStyle(.secondary)
            screenMock
                .environment(\.appIdiom, idiom)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: screen.width * scale, height: screen.height * scale, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private var screenMock: some View {
        let bandHeight = bandFillsScreen ? screen.height : screen.width * 9 / 16
        return VStack(spacing: 0) {
            HeroBand {
                LinearGradient(
                    colors: [Color(red: 0.10, green: 0.16, blue: 0.36),
                             Color(red: 0.02, green: 0.36, blue: 0.44)],
                    startPoint: .top, endPoint: .bottom
                )
            } foreground: {
                PreviewLogoForeground()
            }
            .frame(width: screen.width, height: bandHeight)
            if !bandFillsScreen {
                VStack(alignment: .leading, spacing: Space.s12) {
                    Text("Recently Added")
                        .font(.title3.weight(.semibold))
                    HStack(spacing: Space.s12) {
                        ForEach(0..<6) { _ in
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.fill)
                                .aspectRatio(2 / 3, contentMode: .fit)
                        }
                    }
                }
                .padding(.horizontal, Space.s40)
                .padding(.top, Space.s22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: screen.width, height: screen.height)
        .background(Color.background)
    }
}

/// Permanent diagnostic: the hero logo's proportion of the screen, tvOS vs iPad. Both mock
/// screens are normalized to the SAME displayed width — how each screen fills your field of
/// view — so the logo sizes are directly comparable. The logo box is the real production
/// geometry (`HeroTitle.logoHeight` + `contentMaxWidth`, shared by the Home carousel and both
/// detail headers); only the artwork is mocked. Regression check: the tv wordmark should read
/// at-or-above parity with iPad's — before the 2026-07-15 idiom ramp both idioms shared the
/// iPad 96pt box and the tv logo rendered ~40% smaller relative to its screen.
#Preview("Hero logo scale · tvOS vs iPad", traits: .fixedLayout(width: 1040, height: 1460)) {
    VStack(alignment: .leading, spacing: Space.s22) {
        HeroLogoScalePanel(
            caption: "tvOS · 1920×1080 · full-bleed hero",
            screen: CGSize(width: 1920, height: 1080),
            displayWidth: 960,
            idiom: .tv,
            bandFillsScreen: true
        )
        HeroLogoScalePanel(
            caption: "iPad 13″ landscape · 1376×1032 · 16:9 band",
            screen: CGSize(width: 1376, height: 1032),
            displayWidth: 960,
            idiom: .regular,
            bandFillsScreen: false
        )
    }
    .padding(Space.s22)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(white: 0.08))
    .preferredColorScheme(.dark)
}
