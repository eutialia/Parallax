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
    var autocapitalization: UITextAutocapitalizationType = .none
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
/// field on its own screen is exactly what Apple Settings shows; the field is a `TVKeyboardField`
/// (a UIKit `UITextField` bridge) that RAISES the system keyboard itself, so submitting one field
/// walks to the next with the keyboard staying up — the iOS return-chain experience — instead of
/// dropping back to a bare field that needs another Select to reopen the keyboard.
private struct CredentialEditorFlow: View {
    let rows: [CredentialRow]
    let startIndex: Int
    let onClose: () -> Void
    let onComplete: () -> Void

    @State private var index: Int
    @State private var reveal = false
    /// Bumped on each advance so `TVKeyboardField` re-raises the keyboard for the new field.
    @State private var activation = 0

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

            // The keyboard-raising field. `activation` bumps on each walk forward so the keyboard
            // re-presents for the new field instead of the user having to click Select again.
            TVKeyboardField(
                text: row.text,
                isSecure: row.isSecure && !reveal,
                keyboard: row.keyboard,
                autocapitalization: row.autocapitalization,
                contentType: row.textContentType,
                placeholder: row.placeholder,
                returnKey: isLast ? .go : .next,
                activation: activation,
                onSubmit: advance
            )
            .frame(maxWidth: 760, minHeight: 64)

            if row.isSecure {
                Button(reveal ? "Hide" : "Show") { reveal.toggle() }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .foregroundStyle(Color.secondaryLabel)
            }
        }
        .padding(Space.s60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
        // Menu backs out of the whole editor without committing.
        .onExitCommand(perform: onClose)
        // Walking to the next field rebuilds it; bump `activation` so it re-raises the keyboard.
        .onChange(of: index) {
            reveal = false
            activation += 1
        }
    }

    /// Advance to the next field's editor, or finish (last field's "go").
    private func advance() {
        if isLast { onComplete() } else { index += 1 }
    }
}

/// A tvOS credential field that RAISES THE SYSTEM KEYBOARD itself. SwiftUI's `@FocusState` only
/// *focuses* a `TextField` on tvOS — it lands on the field but leaves the keyboard closed, so the
/// user had to click Select to open it (and again for every field as the chain advanced: the
/// reported "press Next → land on a bare field + unfocusable button → click center again" bug).
/// UIKit's `UITextField.becomeFirstResponder()` *presents* the keyboard directly (UITextField docs:
/// "When a text field becomes first responder, the system automatically shows the keyboard"), so the
/// editor walks field→field with the keyboard staying up.
///
/// NOT unit-tested: keyboard presentation + focus behavior depend on the focus engine and the
/// physical remote, which the simulator doesn't reproduce — verified on device, like
/// `TVRemoteInputView` and `FocusableScrollText`.
private struct TVKeyboardField: UIViewRepresentable {
    let text: Binding<String>
    var isSecure: Bool
    var keyboard: UIKeyboardType
    var autocapitalization: UITextAutocapitalizationType
    var contentType: UITextContentType?
    var placeholder: String
    var returnKey: UIReturnKeyType
    /// A change re-raises the keyboard for the (possibly new) field, so the chain never drops back
    /// to a closed keyboard. The editor bumps it on each advance.
    var activation: Int
    var onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        field.textAlignment = .center
        field.font = .preferredFont(forTextStyle: .title2)
        field.adjustsFontForContentSizeCategory = true
        field.autocorrectionType = .no
        field.textColor = UIColor(Color.label)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text.wrappedValue { field.text = text.wrappedValue }
        field.isSecureTextEntry = isSecure
        field.keyboardType = keyboard
        field.autocapitalizationType = autocapitalization
        field.textContentType = contentType
        field.returnKeyType = returnKey
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIColor(Color.tertiaryLabel)]
        )
        // Present the text-entry scene for this field. tvOS shows text entry as a full-screen SCENE
        // that COMMITS + DISMISSES when the user taps the keyboard's return key (unlike iOS, where the
        // keyboard persists). The reused field stays `isFirstResponder` across that dismissal, so on the
        // walk to the next field a plain `becomeFirstResponder()` no-ops and never re-presents the
        // scene — leaving a focused, keyboardless field rendering its giant tvOS focus halo (the
        // reported "big ball"). On an advance, BOUNCE the responder (resign, then become on the next
        // runloop) so the scene reliably re-presents for the new field; first appear just becomes.
        // Deferred to the next runloop either way so the field is in the hierarchy first (tvOS drops a
        // first-responder set made mid-update).
        if context.coordinator.lastActivation != activation {
            let isAdvance = context.coordinator.lastActivation >= 0
            context.coordinator.lastActivation = activation
            DispatchQueue.main.async {
                if isAdvance {
                    field.resignFirstResponder()
                    DispatchQueue.main.async { field.becomeFirstResponder() }
                } else {
                    field.becomeFirstResponder()
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: TVKeyboardField
        var lastActivation = -1
        init(_ parent: TVKeyboardField) { self.parent = parent }
        @objc func editingChanged(_ field: UITextField) { parent.text.wrappedValue = field.text ?? "" }
        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.onSubmit()
            // The editor drives the chain (advance bumps `activation`); don't resign here or the
            // keyboard would drop before the next field re-raises it.
            return false
        }
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
