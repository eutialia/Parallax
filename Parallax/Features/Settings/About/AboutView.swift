import SwiftUI

/// The About screen — a normal pushed settings sub-screen carrying everything the licenses require
/// the shipped binary itself to say: the GPLv3 identity + source pointer for Parallax, the
/// third-party attribution list (each entry drills into its full bundled license text), the
/// CC-BY-SA credit for the Jellyfin glyph, and the privacy statement. All content renders in-app;
/// URLs are plain text on purpose — tvOS has no browser, and the same rows must read identically
/// on both platforms.
struct AboutView: View {
    var body: some View {
        SettingsScaffold(showsBrand: false) {
            aboutGroup
            privacyGroup
            acknowledgementsGroup
        }
        .navigationTitle("About")
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var aboutGroup: some View {
        SettingsGroup(
            title: "About",
            footer: "Parallax is free software under the GNU General Public License v3. The full "
                + "source code, including everything needed to rebuild this app, lives at the "
                + "address above."
        ) {
            SettingsRowLabel(
                systemImage: "app.badge.checkmark",
                title: "Version",
                value: SettingsBuildLine.versionText
            )
            NavigationLink(value: SettingsView.Route.license(.parallax)) {
                SettingsRowLabel(
                    systemImage: "doc.text",
                    title: "License",
                    value: "GPLv3",
                    accessory: .chevron
                )
            }
            .tvListRowButton()
            SettingsRowLabel(
                systemImage: "chevron.left.forwardslash.chevron.right",
                title: "Source Code",
                subtitle: "github.com/eutialia/Parallax"
            )
        }
    }

    private var privacyGroup: some View {
        SettingsGroup(
            title: "Privacy",
            footer: "Parallax has no accounts of its own and collects nothing. It only talks to "
                + "the media servers you add; your sign-ins stay in the device Keychain and go to "
                + "their own server."
        ) {
            SettingsRowLabel(
                systemImage: "hand.raised",
                title: "Data Collection",
                value: "None"
            )
        }
    }

    private var acknowledgementsGroup: some View {
        SettingsGroup(
            title: "Acknowledgements",
            footer: "Parallax uses AMSMB2 (libsmb2) and VLCKit under the LGPL-2.1. Since the whole "
                + "app is open source, anyone can modify these libraries and rebuild Parallax from "
                + "the repository with standard tooling, which satisfies the LGPL relink requirement."
        ) {
            ForEach(Acknowledgement.all) { entry in
                if entry.license != nil {
                    NavigationLink(value: SettingsView.Route.license(entry)) {
                        row(for: entry)
                    }
                    .tvListRowButton()
                    .accessibilityHint("Shows the full license text")
                } else {
                    row(for: entry)
                }
            }
        }
    }

    private func row(for entry: Acknowledgement) -> some View {
        SettingsRowLabel(
            title: entry.name,
            subtitle: "\(entry.licenseName) · \(entry.url)",
            accessory: entry.license == nil ? .none : .chevron
        )
    }
}

/// One component's attribution + full license text, pushed from an About row. The header carries the
/// per-entry facts the row can't fit (role, © line, upstream address) — for the CC-BY-SA glyph that
/// header IS the required attribution.
///
/// On tvOS the body is NOT plain `Text` inside the scaffold's `ScrollView` — a single focus stop
/// taller than the screen (a bare `.focusable()`) has exactly one valid scroll offset, so tvOS
/// (which scrolls only by moving focus) can never scroll it. Instead the body is a
/// `FocusableScrollText` (bridged, focusable `UITextView`), and the scaffold itself is told
/// `scrolls: false` so the region gets a bounded height straight from the screen instead of an
/// infinite proposal from a nested `ScrollView` — see `SettingsScaffold.tvColumn`.
struct LicenseTextView: View {
    let entry: Acknowledgement

    var body: some View {
        SettingsScaffold(showsBrand: false, scrolls: scaffoldScrolls) {
            header
            licenseBody
        }
        .navigationTitle(entry.name)
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            Text("\(entry.name) · \(entry.role)")
                .font(.rowTitle)
                .foregroundStyle(Color.label)
            Text("\(entry.url) · \(entry.license?.displayName ?? entry.licenseName)")
                .font(.rowSubtitle)
                .foregroundStyle(Color.secondaryLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsMetrics.headerInset)
    }

    @ViewBuilder
    private var licenseBody: some View {
        if let license = entry.license {
            #if os(tvOS)
            // Full-contrast `.label` here (not iOS's `.secondaryLabel` below) is a deliberate
            // divergence for 10-foot legibility, not an oversight.
            FocusableScrollText(text: license.text, textStyle: .footnote, design: .monospaced, textColor: .label)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, SettingsMetrics.headerInset)
            #else
            Text(license.text)
                .font(.footnote.monospaced())
                .foregroundStyle(Color.secondaryLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SettingsMetrics.headerInset)
            #endif
        }
    }

    /// tvOS only — see the type doc comment. iOS keeps the scaffold's normal (default `true`)
    /// ScrollView; touch scrolling already works there and this flag is a no-op on that branch.
    private var scaffoldScrolls: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }
}

#if DEBUG
#if os(tvOS)
#Preview("About (tvOS)", traits: .fixedLayout(width: 1920, height: 1080)) {
    NavigationStack { AboutView() }.screenFloor()
}
#else
#Preview("About (iOS)", traits: .fixedLayout(width: 540, height: 980)) {
    NavigationStack { AboutView() }.screenFloor()
}
#endif

#if os(tvOS)
#Preview("License text · GPLv3 (tvOS)", traits: .fixedLayout(width: 1920, height: 1080)) {
    NavigationStack { LicenseTextView(entry: .parallax) }.screenFloor()
        .frame(width: 1920, height: 1080)
}
#else
#Preview("License text · GPLv3 (iOS)", traits: .fixedLayout(width: 540, height: 980)) {
    NavigationStack { LicenseTextView(entry: .parallax) }.screenFloor()
}
#endif
#endif
