import SwiftUI
import ParallaxJellyfin
import ParallaxCore

/// Hero title treatment: text over `.primary` poster art (logo is often baked in),
/// transparent logo over landscape/backdrop art.
struct HeroTitle: View {
    enum Scale {
        case home
        case detail

        func pointSize(regularWidth: Bool) -> CGFloat {
            switch self {
            case .home: regularWidth ? 52 : 32
            case .detail: regularWidth ? 48 : 30
            }
        }
    }

    let title: String
    let logoRef: ImageRef?
    let session: Session
    let regularWidth: Bool
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
            .scaledFont(scale.pointSize(regularWidth: regularWidth), relativeTo: .largeTitle, weight: .heavy)
            .foregroundStyle(.white)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
    }

    private func logo(_ ref: ImageRef) -> some View {
        JellyfinImage(ref: ref, kind: .logo, session: session, maxWidth: 800, style: .logo)
            .frame(height: regularWidth ? 96 : 60, alignment: .leading)
            .frame(maxWidth: HeroMetrics.contentMaxWidth, alignment: .leading)
            .accessibilityLabel(title)
    }
}

extension HeroTitle {
    init(item: Item, session: Session, regularWidth: Bool, scale: Scale = .home) {
        self.title = item.displayTitle
        self.logoRef = item.heroLogoRef
        self.session = session
        self.regularWidth = regularWidth
        self.usesLogo = item.heroUsesLogoTitle(regularWidth: regularWidth)
        self.scale = scale
    }
}
