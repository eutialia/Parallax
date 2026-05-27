import Foundation

public struct Page<T: Sendable & Hashable>: Sendable, Hashable {
    public let items: [T]
    public let total: Int
    public let nextCursor: PageCursor?

    public init(items: [T], total: Int, nextCursor: PageCursor?) {
        self.items = items
        self.total = total
        self.nextCursor = nextCursor
    }
}
