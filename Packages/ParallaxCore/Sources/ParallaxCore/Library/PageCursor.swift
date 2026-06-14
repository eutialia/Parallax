import Foundation

// Cursor for paginated library fetches. `startIndex` and its factory are
// public so repository implementers in other modules (ParallaxJellyfin today,
// SMB later) can mint cursors; consumers thread the value forward without
// caring about its internals.
public struct PageCursor: Sendable, Hashable {
    public let startIndex: Int

    public static func startIndex(_ value: Int) -> PageCursor {
        PageCursor(startIndex: value)
    }
}
