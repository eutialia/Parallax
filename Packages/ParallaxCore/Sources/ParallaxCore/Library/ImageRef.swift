import Foundation

public struct ImageRef: Sendable, Hashable {
    public let itemID: ItemID
    public let kind: ImageKind
    public let tag: ImageTag
    /// BlurHash string for this exact image (Jellyfin ships one per image tag), decoded by the
    /// app target into the loading placeholder so a cell shows a blurred impression of the
    /// artwork instead of a flat gray box while the real image streams in. Optional and
    /// defaulted so SMB/local refs — which have no server-side BlurHash — and every existing
    /// call site keep compiling untouched.
    public let blurHash: String?

    public init(itemID: ItemID, kind: ImageKind, tag: ImageTag, blurHash: String? = nil) {
        self.itemID = itemID
        self.kind = kind
        self.tag = tag
        self.blurHash = blurHash
    }
}
