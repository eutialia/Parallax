import SwiftUI
import ParallaxJellyfin

/// The logged-out entry point: a source picker in front of the Jellyfin sign-in form, all on ONE
/// sheet floor (no inner card). The brand mark (logo + "Parallax") is rendered ONCE, above the
/// sliding body, so it stays perfectly still while only the subtitle + rows/form slide past each
/// other — no `matchedGeometryEffect` (which fades/jumps under rapid toggling). Tapping "Jellyfin
/// Server" slides the sign-in form in from the right; the form's bottom "Choose a different source"
/// button slides it back. "SMB / Network Share" opens the SMB add flow as a modal nav stack (iOS):
/// saving the first SMB source routes straight to an SMB-only home. tvOS keeps it disabled — its
/// focus root still gates on a Jellyfin session.
///
/// A fixed-height sheet (see `LoggedOutRootView`) keeps the mark from drifting when the body's
/// height changes between the two screens.
struct ConnectSourceView: View {
    private enum Step: Hashable { case choose, jellyfin }
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @State private var step: Step = .choose
    /// Owned here, not inside `LoginView`, so the typed credentials outlive the cover swap (the
    /// form subtree is removed/re-inserted by the transition). Built lazily on first entry.
    @State private var jellyfinViewModel: LoginViewModel?
    /// Drives the SMB add flow, presented as a sheet over the picker. The SMB add is a two-screen
    /// nav flow (connect → folder picker), so it gets its own `NavigationStack` rather than being
    /// forced into the picker's single-screen cover swap (which the Jellyfin form uses).
    @State private var addingSMB = false
    /// Set when the SMB add succeeds so the sheet's `onDismiss` routes to home — see
    /// `markSMBAddedThenDismiss()` for why routing waits until the sheet is fully dismissed.
    @State private var smbAddSucceeded = false

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: Space.s22) {
                // Persistent — rendered once above the swap, never transitions, so the logo is
                // rock-steady. Top inset lifts it high in the sheet.
                AuthBrandMark(glyph: .brandIcon, title: "Parallax")
                    .padding(.top, max(Space.s26, proxy.size.height * AuthLayout.topBias))

                // COVER transition: the picker is always the bottom layer and never moves; the
                // sign-in form slides in from the right ON TOP of it (opaque, so the picker is fully
                // hidden behind — no slide-out "trace"), and slides back off to reveal it again.
                ZStack(alignment: .top) {
                    bodyLayer { chooseBody }
                    if step == .jellyfin {
                        bodyLayer { LoginView(chromeless: true, onBack: { go(to: .choose) }, viewModelOverride: jellyfinViewModel) }
                            .transition(.move(edge: .trailing))
                            .zIndex(1)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .background(Color.background.ignoresSafeArea())
        #if !os(tvOS)
        // SMB add presented as its own modal nav flow (connect → choose folder). On success we
        // dismiss THIS sheet first, then route in `onDismiss` — see `markSMBAddedThenDismiss()`.
        .sheet(isPresented: $addingSMB, onDismiss: routeAfterSMBAddIfNeeded) {
            NavigationStack {
                SMBLoginView(onAdded: { markSMBAddedThenDismiss() })
                    .navigationTitle("Add SMB Server")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { addingSMB = false }
                        }
                    }
            }
            .presentationBackground(Color.background)
        }
        #endif
    }

    #if !os(tvOS)
    /// A first SMB source was saved while logged out. Routing flips `destination` to `.home`, which
    /// unmounts the whole logged-out root — tearing the presenter out from under this still-presented
    /// child sheet is the fragile SwiftUI presentation pattern (dropped dismiss animation / wedged
    /// presentation). So mark success and dismiss the sheet FIRST; `onDismiss` routes once it's gone.
    private func markSMBAddedThenDismiss() {
        smbAddSucceeded = true
        addingSMB = false
    }

    /// Fires after the SMB add sheet fully dismisses. Routes to SMB-only home (no Jellyfin session),
    /// which unmounts the picker and rearms the launch reveal over the first Home boot — the same
    /// path a Jellyfin sign-in takes. A user-cancelled dismiss leaves `smbAddSucceeded` false and
    /// no-ops back to the picker.
    private func routeAfterSMBAddIfNeeded() {
        guard smbAddSucceeded else { return }
        smbAddSucceeded = false
        Task {
            router.updateForSources(
                activeSession: await deps.serverStore.active,
                hasAuxiliarySources: await deps.serverStore.hasSMBServers
            )
        }
    }
    #endif

    /// One screen's body as a full-width, full-height OPAQUE layer: opaque so the outgoing screen is
    /// fully hidden behind the incoming one during the slide (transparent bodies bled through). Caps
    /// the inner content width and scrolls it for overflow, matching `AuthScreenScaffold`.
    @ViewBuilder
    private func bodyLayer<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: 444)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Space.s18)
                .padding(.bottom, Space.s40)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.background)
    }

    private var chooseBody: some View {
        VStack(spacing: Space.s22) {
            AuthSubtitle("Choose how to connect")
            sourceCard
        }
    }

    private func go(to next: Step) {
        // Build the form's model on first entry (owned by the picker, see `jellyfinViewModel`) so
        // it persists across the swap rather than dying with the LoginView subtree.
        if next == .jellyfin, jellyfinViewModel == nil {
            jellyfinViewModel = LoginViewModel(sessionManager: deps.sessionManager)
        }
        withAnimation(.smooth) { step = next }
    }

    /// One grouped `fill` card holding both source rows with a hairline between — the same list
    /// treatment as the LAN-discovered servers and the iOS sign-in fields.
    private var sourceCard: some View {
        VStack(spacing: 0) {
            Button {
                go(to: .jellyfin)
            } label: {
                SourceRow(
                    icon: "hexagon.fill",
                    title: "Jellyfin Server",
                    subtitle: "Sign in to your media server"
                )
                // Make the whole row (icon → trailing chevron, including the Spacer) the tap
                // target, not just the glyph + text.
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            hairline

            #if os(tvOS)
            // tvOS can't reach SMB-only home yet (the focus root still gates on a Jellyfin
            // session) — shown disabled with a Jellyfin-first caption rather than a dead end.
            SourceRow(
                icon: "externaldrive.connected.to.line.below.fill",
                title: "SMB / Network Share",
                subtitle: "Sign in to a Jellyfin server first",
                enabled: false
            )
            #else
            Button {
                addingSMB = true
            } label: {
                SourceRow(
                    icon: "externaldrive.connected.to.line.below.fill",
                    title: "SMB / Network Share",
                    subtitle: "Connect to a network share"
                )
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            #endif
        }
        .background(Color.fill, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
    }

    /// Inset divider aligned under the row titles (past the icon column).
    private var hairline: some View {
        Rectangle()
            .fill(Color.separator)
            .frame(height: 1)
            .padding(.leading, Space.s14 + 28 + Space.s14)
    }
}

/// A single source choice: leading glyph, title + caption, trailing chevron when actionable.
/// Disabled rows drop the chevron and dim — the caption carries the "why".
private struct SourceRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var enabled: Bool = true

    var body: some View {
        HStack(spacing: Space.s14) {
            Image(systemName: icon)
                .scaledFont(20, relativeTo: .title3, weight: .regular)
                .frame(width: 28)
                .foregroundStyle(enabled ? Color.label : Color.tertiaryLabel)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(enabled ? Color.label : Color.secondaryLabel)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(enabled ? Color.secondaryLabel : Color.tertiaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if enabled {
                Image(systemName: "chevron.right")
                    .scaledFont(13, relativeTo: .footnote, weight: .semibold)
                    .foregroundStyle(Color.tertiaryLabel)
            }
        }
        .padding(.vertical, Space.s14)
        .padding(.horizontal, Space.s14)
        .opacity(enabled ? 1 : 0.7)
        // The actionable row gets its button trait + hit area from the wrapping Button; here we just
        // fuse glyph + title + caption into one element so VoiceOver reads each choice as a single
        // phrase (the disabled row stays plain static text — no button trait).
        .accessibilityElement(children: .combine)
        // VoiceOver otherwise reads the disabled row as a plain available choice; the hint says why
        // it can't be picked (the caption already shows it sighted, but combine flattens emphasis).
        .accessibilityHint(enabled ? "" : "Requires a Jellyfin server first")
    }
}

#Preview("Connect source · light") {
    ConnectSourceView()
        .background(Color.background)
        .preferredColorScheme(.light)
}

#Preview("Connect source · dark") {
    ConnectSourceView()
        .background(Color.background)
        .preferredColorScheme(.dark)
}

/// The logged-out root. Owns platform presentation so `RootView`'s `.login` case stays a one-liner:
/// iOS presents `ConnectSourceView` as a sheet over a quiet branded backdrop (iPad centered card /
/// iPhone bottom sheet, matching the Settings panel); tvOS hosts it full-screen (no floating sheet
/// idiom there). The sheet can't be interactively dismissed — there's no signed-in state behind it.
struct LoggedOutRootView: View {
    #if os(tvOS)
    var body: some View {
        ConnectSourceView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.background)
    }
    #else
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var presenting = true

    var body: some View {
        Color.background
            .ignoresSafeArea()
            .sheet(isPresented: $presenting) {
                ConnectSourceView()
                    .connectSheetSizing(compact: hSize == .compact)
                    .presentationBackground(Color.background)
                    .interactiveDismissDisabled()
            }
    }
    #endif
}

#if !os(tvOS)
private extension View {
    /// Pins the connect sheet to a FIXED size so the body's height changing between the picker and
    /// the sign-in form never resizes it (a resizing, bottom-anchored sheet would drift the mark).
    /// iPhone: a single `.large` detent (fixed-height bottom sheet). iPad: the system form card
    /// (already a fixed centered size; the body scrolls within it).
    @ViewBuilder
    func connectSheetSizing(compact: Bool) -> some View {
        if compact {
            self.presentationDetents([.large])
        } else {
            self.presentationSizing(.form)
        }
    }
}
#endif
