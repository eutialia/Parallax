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
                }
                // Custom chip style (gentle lift, no platter) instead of `.plain`, which paints
                // the system focus platter around the glyph on tvOS. `.plain` on iOS.
                .tvChipButton()
                .accessibilityLabel("Clear search")
                .transition(.opacity)
            }
        }
        .padding(.vertical, Space.s12)
        .padding(.horizontal, Space.s14)
        .background(Color.fill, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
        // Same duration as the scope row's show/hide in JellyfinSearchView — both fire on
        // the same empty↔non-empty keystroke, so they should move together.
        .animation(.easeInOut(duration: 0.2), value: text.isEmpty)
    }
}
