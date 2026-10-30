import Foundation
import WallmotionCore

/// Memoizes the projection across playback/volume refreshes. It is deliberately
/// not observable: query and source inputs already drive SwiftUI invalidation.
@MainActor
final class LibraryCatalogProjection {
    private var source: [Wallpaper] = []
    private var query: LibraryQuery?
    private var result: [Wallpaper] = []

    func items(from source: [Wallpaper], query: LibraryQuery) -> [Wallpaper] {
        if self.query != query || self.source != source {
            self.source = source
            self.query = query
            result = query.items(from: source)
        }
        return result
    }
}
