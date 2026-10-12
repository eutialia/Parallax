import SwiftUI
import ParallaxFileBrowse
import ParallaxJellyfin
import ParallaxFeatures

/// Multi-select share picker shown after a successful `listShares()`. Each `SMBShare` returned
/// by the server is presented as a toggleable row; the user picks which shares to mount as
/// libraries. Confirming saves the server through the add flow (`SMBAddServerModel.save`) and fires
/// `onAdded`. The enumeration is already done by the time this appears, so the picker holds no
/// connection of its own.
struct SMBShareSelectionView: View {
    let model: SMBAddServerModel
    var onAdded: () -> Void

    // MARK: - Derived

    private var addButtonTitle: String {
        switch model.selectedShares.count {
        case 0: return "Add Shares"
        case 1: return "Add 1 Share"
        default: return "Add \(model.selectedShares.count) Shares"
        }
    }

    // MARK: - Body

    var body: some View {
        SettingsScaffold(showsBrand: false) {
            VStack(spacing: Space.s18) {
                #if os(tvOS)
                // tvOS has no nav bar (the native pill only reads "Settings"), so the picker carries
                // its own "Choose Shares" identity inline. iOS shows the nav title instead.
                FormIntroHeader(
                    glyph: .symbol("externaldrive.badge.wifi"),
                    title: "Choose Shares",
                    subtitle: "Select one or more shares to add as libraries."
                )
                .padding(.bottom, Space.s8)
                #endif

                SettingsGroup(title: "Shares") {
                    ForEach(model.discoveredShares, id: \.name) { share in
                        ShareSelectionRow(
                            share: share,
                            isSelected: model.selectedShares.contains(share.name),
                            onToggle: { model.toggleShare(share.name) }
                        )
                    }
                }

                if let saveError = model.saveError {
                    Text(saveError)
                        .font(.footnote)
                        .foregroundStyle(Color.destructive)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SettingsMetrics.headerInset)
                }

                Button {
                    Task { if await model.save() { onAdded() } }
                } label: {
                    Text(addButtonTitle).formActionLabel(isWorking: model.isSaving)
                }
                .formActionButton(.solid)
                .disabled(model.selectedShares.isEmpty || model.isSaving)
                .padding(.top, Space.s3)
            }
        }
        .navigationTitle("Choose Shares")
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#if DEBUG
#Preview("SMB share selector · rows", traits: .fixedLayout(width: 540, height: 600)) {
    let stubShares = [
        SMBShare(name: "Media", comment: "Movies & TV"),
        SMBShare(name: "Backups", comment: ""),
        SMBShare(name: "Photos", comment: "Family photos"),
        SMBShare(name: "Downloads", comment: ""),
    ]
    ScrollView {
        VStack(spacing: Space.s18) {
            SettingsGroup(title: "Shares") {
                ForEach(stubShares, id: \.name) { share in
                    ShareSelectionRow(
                        share: share,
                        isSelected: share.name == "Media" || share.name == "Photos",
                        onToggle: {}
                    )
                }
            }
            Button {} label: { Text("Add 2 Shares").formActionLabel() }
                .formActionButton(.solid)
        }
        .padding(Space.s18)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color.background)
}
#endif
