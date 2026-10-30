import Foundation

public enum LibraryMediaFilter: String, CaseIterable, Sendable {
    case all, photos, gifs, videos, web

    public func includes(_ item: Wallpaper) -> Bool {
        if self == .all { return true }
        if case .web = item.source { return self == .web }
        switch self {
        case .photos: return item.kind == .image
        case .gifs: return item.kind == .gif
        case .videos: return item.kind == .video
        case .web, .all: return false
        }
    }

    private static func rank(_ item: Wallpaper) -> Int {
        if case .web = item.source { return 3 }
        switch item.kind { case .image: return 0; case .gif: return 1; case .video: return 2 }
    }

    fileprivate static func precedes(_ left: Wallpaper, _ right: Wallpaper) -> Bool? {
        let a = rank(left), b = rank(right)
        return a == b ? nil : a < b
    }
}

public enum LibrarySortOrder: String, CaseIterable, Sendable {
    case recent, title, mediaType
}

public struct LibraryQuery: Equatable, Sendable {
    public var text: String
    public var filter: LibraryMediaFilter
    public var sort: LibrarySortOrder

    public init(text: String = "", filter: LibraryMediaFilter = .all, sort: LibrarySortOrder = .recent) {
        self.text = text
        self.filter = filter
        self.sort = sort
    }

    /// A projection only: never changes the library's stored order/assignments.
    public func items(from items: [Wallpaper]) -> [Wallpaper] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = items.filter { item in
            filter.includes(item) && (needle.isEmpty || item.title.range(of: needle,
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current) != nil)
        }
        return matching.sorted { left, right in
            switch sort {
            case .recent:
                if left.addedAt != right.addedAt { return left.addedAt > right.addedAt }
            case .title: break
            case .mediaType:
                if let comparison = LibraryMediaFilter.precedes(left, right) { return comparison }
            }
            if sort != .recent {
                let comparison = left.title.localizedStandardCompare(right.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            }
            return left.id.uuidString < right.id.uuidString
        }
    }
}
