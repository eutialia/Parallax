#if os(tvOS)
import os
import ParallaxCore
import SwiftUI
import UIKit

/// One credential a `CredentialRowList` collects: a label, a binding to its value, and the keyboard
/// configuration the editing field uses.
struct CredentialRow: Identifiable {
    let id: String
    let title: String
    let placeholder: String
    let text: Binding<String>
    var isSecure: Bool = false
    var keyboard: UIKeyboardType = .default
    /// Drives Password AutoFill / the QuickType bar over the Continuity / Remote keyboard for
    /// `.username`/`.password` rows. Left nil (SMB rows) it's a no-op.
    var textContentType: UITextContentType?
}

/// tvOS credential entry — the Apple-Settings idiom, and the one shape Apple's own guidance sanctions
/// for the 10-foot UI. Apple's HIG is explicit that "text input in tvOS is minimal by design": text
/// fields get no multi-field treatment ("no additional considerations for tvOS"), the system presents
/// one full-screen keyboard per field, and the prescription for anything beyond a little data is to
/// minimize entry or let people use another device. There is no "advance to the next field" pattern to
/// build because Apple doesn't ship one — typing on the remote is meant to be rare. (Jellyfin's
/// no-typing path is Quick Connect; this is SMB's minimal-entry path.)
///
/// Each field is a display-only PILL (label + current value + chevron). Selecting a pill raises the
/// system keyboard for THAT field: a hidden `UITextField` per row lives behind the pills and we call
/// `becomeFirstResponder()` on it — Apple's documented way to "force a text field to become first
/// responder when you require the user to enter some information," which opens the keyboard on the FIRST
/// press with no intermediate screen. Typing commits back to the pill; Done returns to the form; the
/// user selects the next pill. The always-present Connect button submits.
///
/// See [[tvos-textfield-becomefirstresponder-keyboard]] (the device-proven dead ends — UIKit's archival
/// Next/Previous auto-walk and SwiftUI `@FocusState` both fail to raise the tvOS keyboard, so we don't
/// fake an advance) and [[tvos-textfield-pill-removal]] (why the field hides behind a pill: a native
/// focused field's giant lift breaks the flat settings design).
struct CredentialRowList: View {
    let rows: [CredentialRow]
    /// Host-bumped sweep trigger (e.g. SMBLoginView increments it on Connect): any change releases
    /// stale hidden-field first responders. See `resignRequest` for why the sweep exists.
    var sweepToken: Int = 0

    /// Index of the field a pill tap wants to edit. The host consumes it (raises that field's keyboard)
    /// and clears it.
    @State private var focusRequest: Int?
    /// Asks the host to resign any hidden field still FIRST RESPONDER. tvOS can retain the edited
    /// field as first responder past the keyboard's dismissal (device-observed; `beginEditing`
    /// works around the same retention), and a stale first responder can swallow the remote's Menu
    /// press before it pops navigation — the "stuck on the form, kill the app" freeze. Triggers are
    /// chosen so a sweep can NEVER fire mid-edit: a pill of OURS gaining remote focus, or the
    /// enclosing form bumping `sweepToken` (its Connect press) — both only happen with the keyboard
    /// closed. (`textFieldDidEndEditing` also sweeps, but device runs suggest it may never fire.)
    @State private var resignRequest = false

    var body: some View {
        VStack(spacing: Space.s8) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                // The pill is the focus target (its flat white-fill platter via `settingsPillLayout`);
                // the real field is hidden in the host below — selecting the pill raises its keyboard.
                Button { focusRequest = index } label: { rowLabel(row) }
                    .tvListRowButton()
                    .focused($focusedRow, equals: row.id)
            }
        }
        // The hidden field host sits behind the pills so its text fields are in the window's responder
        // hierarchy (becomeFirstResponder needs that) without taking remote focus or layout space. The
        // full-screen keyboard covers the form while editing, so the host is never seen — and there's
        // no intermediate "fields page": selecting a pill goes straight to the keyboard.
        .background {
            CredentialKeyboardHost(rows: rows, focusRequest: $focusRequest, resignRequest: $resignRequest)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        // A pill gaining focus means the user is back on the FORM — any field still first
        // responder is stale by definition. Nil changes are ignored: focus leaving the list says
        // nothing about the keyboard.
        .onChange(of: focusedRow) { _, focused in
            guard focused != nil else { return }
            resignRequest = true
        }
        .onChange(of: sweepToken) { _, _ in resignRequest = true }
    }

    @FocusState private var focusedRow: String?

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

// MARK: - tvOS keyboard host

/// Hosts one hidden `UITextField` per credential, behind the pills. Selecting a pill calls
/// `becomeFirstResponder()` on that field, which raises tvOS's full-screen keyboard for it; typing
/// syncs back to the row's binding; the keyboard's Done commits and returns to the form.
///
/// NOT unit-tested: keyboard presentation depends on the focus engine and the physical remote, which
/// the simulator doesn't reproduce — verified on device, like `TVRemoteInputView`.
private struct CredentialKeyboardHost: UIViewControllerRepresentable {
    let rows: [CredentialRow]
    @Binding var focusRequest: Int?
    @Binding var resignRequest: Bool

    func makeUIViewController(context: Context) -> CredentialKeyboardController {
        let controller = CredentialKeyboardController()
        controller.coordinator = context.coordinator
        context.coordinator.controller = controller
        controller.rows = rows
        return controller
    }

    func updateUIViewController(_ controller: CredentialKeyboardController, context: Context) {
        context.coordinator.parent = self
        controller.loadViewIfNeeded()   // ensure the fields are built before we sync / focus
        controller.syncText(rows: rows)
        if let index = focusRequest {
            controller.beginEditing(at: index)
            // Clear AFTER this update cycle — never mutate observed state mid-update.
            DispatchQueue.main.async { focusRequest = nil }
        }
        if resignRequest {
            controller.resignStaleFields()
            DispatchQueue.main.async { resignRequest = false }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: CredentialKeyboardHost
        weak var controller: CredentialKeyboardController?
        init(_ parent: CredentialKeyboardHost) { self.parent = parent }

        /// Live-sync each keystroke back to the row's binding so the pill reflects the value.
        @objc func editingChanged(_ field: UITextField) {
            write(field)
        }

        /// Commit (Done) re-syncs as a safety net; `editingChanged` already wrote each keystroke live, so
        /// the binding is current either way — a Menu `.cancelled` does NOT revert (the typed text stays,
        /// which is the pill-reflects-live-value contract). No advance/dismiss to manage.
        func textFieldDidEndEditing(_ field: UITextField, reason: UITextField.DidEndEditingReason) {
            if reason == .committed { write(field) }
            // tvOS can RETAIN the field as first responder past the keyboard scene's dismissal
            // (the same quirk `beginEditing` resigns around when re-opening a pill). A stale first
            // responder sits ahead of the focus system in the press-responder chain and can
            // swallow the remote's Menu press before it pops navigation — the device-reported
            // "stuck on the SMB form, had to kill the app" freeze. Sweep on the next runloop turn
            // (resigning inside the end-editing callback would recurse into it).
            DispatchQueue.main.async {
                if field.isFirstResponder { field.resignFirstResponder() }
            }
        }

        private func write(_ field: UITextField) {
            let index = field.tag
            guard parent.rows.indices.contains(index) else { return }
            parent.rows[index].text.wrappedValue = field.text ?? ""
        }
    }
}

private final class CredentialKeyboardController: UIViewController {
    private static let logger = Log.custom(category: "CredentialRowList")

    weak var coordinator: CredentialKeyboardHost.Coordinator?
    var rows: [CredentialRow] = []

    private var fields: [UITextField] = []
    private let stack = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        // A vertical stack lays the hidden fields behind the pills (near-transparent, not remote-
        // focusable). They only need to exist in the hierarchy so becomeFirstResponder can raise each.
        stack.axis = .vertical
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        fields = rows.enumerated().map { index, row in
            let field = CredentialHiddenTextField()
            field.tag = index
            field.delegate = coordinator
            field.addTarget(
                coordinator,
                action: #selector(CredentialKeyboardHost.Coordinator.editingChanged(_:)),
                for: .editingChanged
            )
            configure(field, with: row)
            stack.addArrangedSubview(field)
            return field
        }
    }

    /// Releases any hidden field still claiming first responder while its keyboard is gone (see
    /// `CredentialRowList.resignRequest`). Callers guarantee the keyboard is closed when this runs,
    /// so resigning here can never kill a live editing session. Logged: a hit on a device run is
    /// direct evidence the stale-first-responder freeze theory is right.
    func resignStaleFields() {
        for field in fields where field.isFirstResponder {
            Self.logger.info("Resigning stale first responder (field tag \(field.tag))")
            field.resignFirstResponder()
        }
    }

    /// Keep field text in step with the bindings (e.g. re-opening a filled field shows its value).
    /// Skip the field currently being edited: it's the source of truth while first responder, so a
    /// binding that lags a keystroke can't clobber the user's latest input.
    func syncText(rows: [CredentialRow]) {
        for (index, row) in rows.enumerated() where fields.indices.contains(index) {
            let field = fields[index]
            if field.isFirstResponder { continue }
            if field.text != row.text.wrappedValue { field.text = row.text.wrappedValue }
        }
    }

    /// Raise the full-screen keyboard for `index`. One hop to the main queue so the field is settled in
    /// the window first (tvOS drops a first-responder set made mid-update); becomeFirstResponder is the
    /// one mechanism that reliably opens the tvOS keyboard.
    func beginEditing(at index: Int) {
        guard fields.indices.contains(index) else { return }
        let field = fields[index]
        DispatchQueue.main.async { [weak self] in
            guard self?.view.window != nil else { return }
            // If the field is still first responder from a prior edit (tvOS can keep it across the
            // keyboard scene's commit/dismiss), a bare becomeFirstResponder() no-ops and the editor
            // never re-presents — resign first so re-selecting the SAME pill re-opens the keyboard.
            if field.isFirstResponder { field.resignFirstResponder() }
            _ = field.becomeFirstResponder()
        }
    }

    private func configure(_ field: UITextField, with row: CredentialRow) {
        field.isSecureTextEntry = row.isSecure
        field.keyboardType = row.keyboard
        field.textContentType = row.textContentType
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.text = row.text.wrappedValue
        // tvOS shows the placeholder as the prompt atop the keyboard, so it carries the human title
        // ("Server", "Username"); the pill keeps `row.placeholder` for its own empty-state hint.
        field.placeholder = row.title
        field.accessibilityLabel = row.title
    }
}

/// A `UITextField` the remote's focus engine can't land on (so it never shows the giant tvOS field
/// focus-lift on the form) but that still raises the keyboard when made first responder
/// programmatically. `canBecomeFocused` (focus engine) and `canBecomeFirstResponder` (responder chain)
/// are independent: per Apple's docs `becomeFirstResponder()` checks `canBecomeFirstResponder` — left at
/// the `UITextField` default of `true` here — not focusability, then displays the field's input view.
private final class CredentialHiddenTextField: UITextField {
    override init(frame: CGRect) {
        super.init(frame: frame)
        alpha = 0.02            // not 0 — a fully hidden field can refuse first responder
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var canBecomeFocused: Bool { false }
}

#if DEBUG
/// Resting appearance: filled, empty, and secure values as standalone pills. Render on the tvOS
/// destination; selecting a pill on a device raises the system keyboard for that field.
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
