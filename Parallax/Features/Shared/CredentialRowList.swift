#if os(tvOS)
import SwiftUI
import UIKit

/// One credential a `CredentialRowList` collects: an icon + label, a binding to its value, and the
/// keyboard configuration its editor screen uses.
struct CredentialRow: Identifiable {
    let id: String
    let icon: String
    let title: String
    let placeholder: String
    let text: Binding<String>
    var isSecure: Bool = false
    var keyboard: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .never
    /// Drives Password AutoFill on the editor field. tvOS surfaces the QuickType bar over the
    /// Continuity / Remote keyboard for `.username`/`.password` rows and auto-advances focus to the
    /// login button once both fill. Left nil (SMB rows) it's a no-op.
    var textContentType: UITextContentType?
}

/// tvOS credential entry, the Apple-Settings idiom. Each field is a focusable ROW
/// (icon · label · current value · chevron) with NO inline text-field chrome at rest — selecting a
/// row presents a dedicated single-field editor where the system keyboard takes over. So the
/// focus-lifting field "pill" appears at most ONCE, centered on its own screen, instead of five
/// crammed into a grouped box where they overflow their rows and clip on the focus lift.
///
/// Why this and not a styled inline `TextField`: on tvOS the pill + focus-lift can't be removed from
/// an inline field via any SwiftUI API (`.plain` keeps the lift, `.focusEffectDisabled()` is broken,
/// `UIView.focusEffect` is tvOS-unavailable — only a `UITextField` subclass override can, and even
/// that needs a hand-built focus indicator). The Settings pattern sidesteps the whole problem.
/// iOS keeps the inline grouped fields, so this view is tvOS-only by construction.
struct CredentialRowList: View {
    let rows: [CredentialRow]

    /// The row currently being edited (its `id`); drives the single-field editor cover.
    @State private var editingID: String?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                Button { editingID = row.id } label: { rowLabel(row) }
                    // `.borderless` is the app's tvOS focusable-row style: the system highlights the
                    // whole row on focus. A row highlighting is correct (it's a button) — unlike the
                    // text-field pill we're avoiding.
                    .buttonStyle(.borderless)
                if index < rows.count - 1 {
                    Rectangle().fill(Color.separator).frame(height: 1).padding(.leading, 56)
                }
            }
        }
        .background(Color.fill, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
        // `.sheet` clips on tvOS — `fullScreenCover` is the tvOS-safe presentation, and the system
        // keyboard wants the full screen anyway. Keyed off `editingID` so the editor binds straight
        // to the row's value binding (typing updates the form live).
        .fullScreenCover(item: Binding(
            get: { rows.first { $0.id == editingID } },
            set: { editingID = $0?.id }
        )) { row in
            CredentialEditor(row: row) { editingID = nil }
        }
    }

    private func rowLabel(_ row: CredentialRow) -> some View {
        HStack(spacing: Space.s18) {
            Image(systemName: row.icon)
                .foregroundStyle(Color.secondaryLabel)
                .frame(width: 38)
            Text(row.title)
                .foregroundStyle(Color.label)
            Spacer(minLength: Space.s18)
            Text(displayValue(row))
                .foregroundStyle(row.text.wrappedValue.isEmpty ? Color.tertiaryLabel : Color.secondaryLabel)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.tertiaryLabel)
        }
        .padding(.horizontal, Space.s22)
        .padding(.vertical, Space.s18)
        .contentShape(.rect)
    }

    /// The trailing value: the live text, a dot-mask for secure fields, or the placeholder (dimmed)
    /// while empty.
    private func displayValue(_ row: CredentialRow) -> String {
        let value = row.text.wrappedValue
        if value.isEmpty { return row.placeholder }
        return row.isSecure ? String(repeating: "•", count: min(value.count, 12)) : value
    }
}

/// The single-field editor a row pushes into: one centered field that the system keyboard fills.
/// A lone field on its own screen is exactly what Apple Settings shows, so the focus pill it still
/// gets reads as intentional.
private struct CredentialEditor: View {
    let row: CredentialRow
    let onDone: () -> Void

    @FocusState private var focused: Bool
    @State private var reveal = false

    var body: some View {
        VStack(spacing: Space.s30) {
            Text(row.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.label)

            field
                .keyboardType(row.keyboard)
                .textInputAutocapitalization(row.autocapitalization)
                .autocorrectionDisabled()
                .textContentType(row.textContentType)
                .focused($focused)
                .frame(maxWidth: 760)
                .onSubmit(onDone)

            if row.isSecure {
                Button(reveal ? "Hide" : "Show") { reveal.toggle() }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .foregroundStyle(Color.secondaryLabel)
            }

            Button("Done", action: onDone)
                .buttonStyle(.borderless)
                .font(.headline)
        }
        .padding(Space.s60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
        // Menu button backs out of the editor without committing through Done.
        .onExitCommand(perform: onDone)
        // tvOS can drop a focus set synchronously on first appear; defer a hair so the field
        // reliably takes focus (and is one click from raising the keyboard).
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            focused = true
        }
    }

    @ViewBuilder
    private var field: some View {
        if row.isSecure && !reveal {
            SecureField("", text: row.text, prompt: prompt)
        } else {
            TextField("", text: row.text, prompt: prompt)
        }
    }

    /// The placeholder forced to the dimmed placeholder gray. A URL-shaped placeholder (the Jellyfin
    /// `Server` row) otherwise gets auto-styled as a blue link that ignores `.tint`/`.foregroundStyle`
    /// — same trap `LoginView.urlPrompt` sidesteps on iOS. Feeding it as an `AttributedString` with an
    /// explicit color renders the normal gray; harmless for the non-URL rows (already gray).
    private var prompt: Text {
        var attributed = AttributedString(row.placeholder)
        attributed.swiftUI.foregroundColor = Color.tertiaryLabel
        return Text(attributed)
    }
}

#if DEBUG
/// Resting appearance of the row list: filled, empty, and secure values side by side. Render this on
/// the tvOS destination to verify rows read as a clean Settings-style group (no field pills) and the
/// focused row highlights without overflowing — then focus a row to check the editor cover.
#Preview("Credential rows", traits: .fixedLayout(width: 1000, height: 620)) {
    @Previewable @State var host = "192.168.1.10"
    @Previewable @State var share = ""
    @Previewable @State var user = "alice"
    @Previewable @State var pass = "hunter2"
    CredentialRowList(rows: [
        CredentialRow(id: "host", icon: "server.rack", title: "Host", placeholder: "e.g. 192.168.1.10", text: $host, keyboard: .URL),
        CredentialRow(id: "share", icon: "externaldrive.connected.to.line.below.fill", title: "Share name", placeholder: "Share name", text: $share),
        CredentialRow(id: "username", icon: "person", title: "Username", placeholder: "Username", text: $user),
        CredentialRow(id: "password", icon: "lock", title: "Password", placeholder: "Password", text: $pass, isSecure: true),
    ])
    .frame(maxWidth: 760)
    .padding(60)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.background)
    .preferredColorScheme(.dark)
}
#endif
#endif
