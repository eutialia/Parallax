#if os(tvOS)
import SwiftUI
import UIKit

/// One credential a `CredentialRowList` collects: a label, a binding to its value, and the keyboard
/// configuration its editor screen uses.
struct CredentialRow: Identifiable {
    let id: String
    let title: String
    let placeholder: String
    let text: Binding<String>
    var isSecure: Bool = false
    var keyboard: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .never
    /// Drives Password AutoFill / the QuickType bar over the Continuity / Remote keyboard for
    /// `.username`/`.password` rows. Left nil (SMB rows) it's a no-op.
    var textContentType: UITextContentType?
}

/// tvOS credential entry, the Apple-Settings idiom: each field is a standalone focus PILL (label +
/// current value + chevron) with NO inline text-field chrome at rest — so the layout never inherits the
/// "comically large" native field focus-LIFT that blows up the 10-foot grid on a real device (the sim
/// under-renders it; see [[tvos-textfield-pill-removal]]). Selecting a pill presents a single-field
/// editor where the system keyboard takes over; submitting WALKS FORWARD to the next field's editor in
/// place — never back to the form — so the keyboard chain advances like the iOS return chain. The last
/// field runs `onSubmit`.
struct CredentialRowList: View {
    let rows: [CredentialRow]
    /// Run when the LAST field is submitted (its "go" key), mirroring the iOS chain so the form can
    /// sign in / connect without bouncing back to the button. Defaults to a no-op.
    var onSubmit: () -> Void = {}

    /// The field whose editor is open (index into `rows`); nil = back on the form. The editor walks
    /// this forward as the user submits each field.
    @State private var editingIndex: Int?

    var body: some View {
        VStack(spacing: Space.s8) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                // The pill is the focus target (its own flat white-fill platter via `settingsPill()`);
                // the editable field lives on a pushed screen, NOT inline, to dodge the native field lift.
                Button { editingIndex = index } label: { rowLabel(row) }
                    .tvListRowButton()
            }
        }
        // ONE persistent cover that walks the fields. `.sheet` clips on tvOS, so `fullScreenCover` is
        // the tvOS-safe full-screen presentation the system keyboard wants anyway.
        .fullScreenCover(isPresented: Binding(
            get: { editingIndex != nil },
            set: { if !$0 { editingIndex = nil } }
        )) {
            if let start = editingIndex {
                CredentialEditorFlow(
                    rows: rows,
                    startIndex: start,
                    onClose: { editingIndex = nil },
                    onComplete: { editingIndex = nil; onSubmit() }
                )
            }
        }
    }

    private func rowLabel(_ row: CredentialRow) -> some View {
        HStack(spacing: Space.s14) {
            Text(row.title)
                .font(.rowBody)
                .foregroundStyle(Color.label)
            Spacer(minLength: Space.s14)
            Text(displayValue(row))
                .font(.rowBody)
                .foregroundStyle(row.text.wrappedValue.isEmpty ? Color.tertiaryLabel : Color.secondaryLabel)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.right")
                .font(.rowSubtitle.weight(.semibold))
                .foregroundStyle(Color.tertiaryLabel)
        }
        .settingsPillLayout()
    }

    /// The trailing value: the live text, a dot-mask for secure fields, or the placeholder (dimmed)
    /// while empty.
    private func displayValue(_ row: CredentialRow) -> String {
        let value = row.text.wrappedValue
        if value.isEmpty { return row.placeholder }
        return row.isSecure ? String(repeating: "•", count: min(value.count, 12)) : value
    }
}

/// The single-field editor the cover presents, walking forward through the fields. A lone centered
/// field on its own screen is exactly what Apple Settings shows (so the focus pill it DOES get reads as
/// intentional); submit advances to the next field IN PLACE instead of dismissing, so the user isn't
/// bounced back to the form between fields.
private struct CredentialEditorFlow: View {
    let rows: [CredentialRow]
    let startIndex: Int
    let onClose: () -> Void
    let onComplete: () -> Void

    @State private var index: Int
    @FocusState private var focused: Bool
    @State private var reveal = false

    init(rows: [CredentialRow], startIndex: Int, onClose: @escaping () -> Void, onComplete: @escaping () -> Void) {
        self.rows = rows
        self.startIndex = startIndex
        self.onClose = onClose
        self.onComplete = onComplete
        _index = State(initialValue: startIndex)
    }

    private var row: CredentialRow { rows[index] }
    private var isLast: Bool { index >= rows.count - 1 }

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
                .submitLabel(isLast ? .go : .next)
                .onSubmit(advance)

            if row.isSecure {
                Button(reveal ? "Hide" : "Show") { reveal.toggle() }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .foregroundStyle(Color.secondaryLabel)
            }

            Button(isLast ? "Done" : "Next", action: advance)
                .buttonStyle(.borderless)
                .font(.headline)
        }
        .padding(Space.s60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
        // Menu backs out of the whole editor without committing.
        .onExitCommand(perform: onClose)
        // tvOS can drop a focus set synchronously on first appear; defer a hair so the field reliably
        // takes focus (and is one click from raising the keyboard).
        .task { await refocusField() }
        // Walking to the next field rebuilds the field; re-assert focus so it's ready to type.
        .onChange(of: index) {
            reveal = false
            Task { await refocusField() }
        }
    }

    /// Re-assert field focus after a short defer — tvOS can drop a focus set made synchronously while
    /// the field's editor is still settling (on first appear AND on each walk to the next field).
    private func refocusField() async {
        try? await Task.sleep(for: .milliseconds(50))
        focused = true
    }

    /// Advance to the next field's editor, or finish (last field's "go").
    private func advance() {
        if isLast { onComplete() } else { index += 1 }
    }

    @ViewBuilder
    private var field: some View {
        if row.isSecure && !reveal {
            SecureField("", text: row.text, prompt: prompt)
        } else {
            TextField("", text: row.text, prompt: prompt)
        }
    }

    /// The placeholder forced to the dimmed gray (a URL-shaped placeholder otherwise auto-styles as a
    /// blue link that ignores `.foregroundStyle`).
    private var prompt: Text {
        var attributed = AttributedString(row.placeholder)
        attributed.swiftUI.foregroundColor = Color.tertiaryLabel
        return Text(attributed)
    }
}

#if DEBUG
/// Resting appearance: filled, empty, and secure values as standalone pills. Render on the tvOS
/// destination, then select a pill to check the editor cover walks forward on submit.
#Preview("Credential rows", traits: .fixedLayout(width: 1000, height: 620)) {
    @Previewable @State var host = "192.168.1.10"
    @Previewable @State var share = ""
    @Previewable @State var user = "alice"
    @Previewable @State var pass = "hunter2"
    CredentialRowList(rows: [
        CredentialRow(id: "host", title: "Host", placeholder: "e.g. 192.168.1.10", text: $host, keyboard: .URL),
        CredentialRow(id: "share", title: "Share name", placeholder: "Share name", text: $share),
        CredentialRow(id: "username", title: "Username", placeholder: "Username", text: $user),
        CredentialRow(id: "password", title: "Password", placeholder: "Password", text: $pass, isSecure: true),
    ])
    .frame(maxWidth: 760)
    .padding(60)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.background)
    .preferredColorScheme(.dark)
}
#endif
#endif
