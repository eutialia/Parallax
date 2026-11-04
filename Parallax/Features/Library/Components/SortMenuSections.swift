#if !os(tvOS)
import SwiftUI

/// A sort menu's shared top: the direction pair as the Photos-style tile row (a `ControlGroup`
/// inside a `Menu` renders each option as a tile with its icon above its title, the selected one
/// in a pill), then the fields as an inline picker.
struct SortMenuSections<Field: Hashable, Direction: Hashable>: View {
    let fields: [Field]
    let field: Field
    let fieldLabel: (Field) -> String
    let directionOptions: [SortDirectionOption<Direction>]
    let direction: Direction
    let onSelectField: (Field) -> Void
    let onSelectDirection: (Direction) -> Void

    var body: some View {
        ControlGroup {
            ForEach(directionOptions, id: \.direction) { option in
                Toggle(isOn: Binding(get: { direction == option.direction },
                                     set: { _ in onSelectDirection(option.direction) })) {
                    Label(option.title, systemImage: option.icon)
                }
            }
        }
        Picker("Sort By", selection: Binding(get: { field }, set: onSelectField)) {
            ForEach(fields, id: \.self) { Text(fieldLabel($0)).tag($0) }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}
#endif
