import Foundation

// Opaque to callers. Only LibraryRepository constructs PageCursors; the
// startIndex constructor is internal so consumers can thread the cursor
// forward but cannot fabricate one with an arbitrary offset.
public struct PageCursor: Sendable, Hashable {
    let startIndex: Int

    static func startIndex(_ value: Int) -> PageCursor {
        PageCursor(startIndex: value)
    }
}
