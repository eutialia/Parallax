import Foundation

public struct ImageRef: Sendable, Hashable {
    public let itemID: ItemID
    public let kind: ImageKind
    public let tag: ImageTag

    public init(itemID: ItemID, kind: ImageKind, tag: ImageTag) {
        self.itemID = itemID
        self.kind = kind
        self.tag = tag
    }
}
