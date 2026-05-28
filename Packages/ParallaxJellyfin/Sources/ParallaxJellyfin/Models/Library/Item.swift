import Foundation

public enum Item: Sendable, Hashable, Identifiable {
    case movie(Movie)
    case series(Series)
    case episode(Episode)

    public var id: ItemID {
        switch self {
        case .movie(let m): return m.id
        case .series(let s): return s.id
        case .episode(let e): return e.id
        }
    }

    public var displayTitle: String {
        switch self {
        case .movie(let m): return m.title
        case .series(let s): return s.title
        case .episode(let e): return e.name
        }
    }

    public var runtime: Duration? {
        switch self {
        case .movie(let m): return m.runtime
        case .series: return nil
        case .episode(let e): return e.runtime
        }
    }

    public var userData: UserItemData {
        switch self {
        case .movie(let m): return m.userData
        case .series(let s): return s.userData
        case .episode(let e): return e.userData
        }
    }
}
