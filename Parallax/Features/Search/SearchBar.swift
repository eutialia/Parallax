import SwiftUI

/// A self-contained search field — rounded fill, leading magnifier, trailing clear
/// button — used in place of the system `.searchable` chrome.
///
/// Why custom: in iPadOS 26 `.searchable` on a `NavigationStack` inside a
/// `.sidebarAdaptable` TabView hoists the field into the top-trailing Liquid Glass
/// slot on focus (ignoring `navigationBarDrawer`), reflows the layout, and lets the
/// search presentation seize the sidebar toggle. A plain field keeps the search UI
/// in the content where it stays put and where we own focus.
struct SearchBar: View {
    @Binding var text: String
    var prompt: String = "Search"
    /// Focus is owned by the parent so the screen can dismiss the keyboard on tap/scroll.
    var focus: FocusState<Bool>.Binding
    var onSubmit: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.s8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.secondaryLabel)
                .accessibilityHidden(true)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused(focus)
                .onSubmit(onSubmit)
                .foregroundStyle(Color.label)
                // Native `.searchable` gives this for free; a custom field must opt in so
                // VoiceOver announces it as a search field, not a plain text field.
                .accessibilityAddTraits(.isSearchField)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.tertiaryLabel)
                        // 44×44 tap target (HIG minimum) without growing the bar: the contentShape
                        // stays 44pt and hittable, while the negative vertical padding reclaims the
                        // height the glyph would otherwise add to the row (it overflows the padding
                        // band, which the non-clipping HStack still hit-tests).
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                        .padding(.vertical, -Space.s12)
                }
                // Native borderless: the system lifts/highlights the glyph on tvOS focus.
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear search")
                .transition(.opacity)
            }
        }
        .padding(.vertical, Space.s12)
        .padding(.horizontal, Space.s14)
        // Capsule, not a 14pt rounded-rect: the search field joins the app's pill language (settings
        // rows, sidebar highlight, the Play pill) instead of reading as a squared block beside them.
        .background(Color.fill, in: Capsule())
        // Same duration as the scope row's show/hide in JellyfinSearchView — both fire on
        // the same empty↔non-empty keystroke, so they should move together. Instant under Reduce Motion.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: text.isEmpty)
    }
}

#if DEBUG
#Preview("SearchBar · empty + filled") {
    @Previewable @FocusState var focus: Bool
    @Previewable @State var empty = ""
    @Previewable @State var filled = "Blade Runner"
    return VStack(spacing: Space.s16) {
        SearchBar(text: $empty, prompt: "Search your library", focus: $focus)
        SearchBar(text: $filled, prompt: "Search your library", focus: $focus)
    }
    .padding()
    .background(Color.background)
}
#endif
