import SwiftUI

/// Return-key field advance for the iOS sign-in forms. Each text field keyed by a `CaseIterable`
/// field enum gets the right `submitLabel` — "next" for intermediate fields, "go" for the last —
/// and its return key moves focus to the FOLLOWING field, or runs `onComplete` on the final one.
/// Without it the keyboard's return just dismisses, stranding the user mid-form instead of walking
/// them down the fields.
///
/// The "next" field is derived from the enum's `allCases` order, so the field sequence is defined
/// once by how the cases are declared — no hand-maintained adjacency list to drift from the layout.
///
/// tvOS enters credentials through `CredentialRowList` (one field per pushed screen), so only the
/// iOS inline forms wire this — but it's pure view/focus logic with no `#if os`, so it lives in the
/// shared layer like any other reusable modifier.
extension View {
    func submitChain<Field: Hashable & CaseIterable>(
        _ field: Field,
        focus: FocusState<Field?>.Binding,
        onComplete: @escaping () -> Void
    ) -> some View {
        let order = Array(Field.allCases)
        let next = order.firstIndex(of: field)
            .map { $0 + 1 }
            .flatMap { $0 < order.count ? order[$0] : nil }
        return self
            .focused(focus, equals: field)
            .submitLabel(next == nil ? .go : .next)
            .onSubmit {
                if let next {
                    focus.wrappedValue = next
                } else {
                    onComplete()
                }
            }
    }
}
