import XCTest
import WallmotionCore
@testable import Wallmotion

@MainActor
final class LibraryCatalogProjectionTests: XCTestCase {
    func testProjectionRefreshesAfterSourceAndQueryChanges() {
        let catalog = LibraryCatalogProjection()
        var photos = [Wallpaper(title: "B", kind: .image, source: .local(filename: "b.png")),
                      Wallpaper(title: "A", kind: .image, source: .local(filename: "a.png"))]
        let byTitle = LibraryQuery(sort: .title)
        XCTAssertEqual(catalog.items(from: photos, query: byTitle).map(\.title), ["A", "B"])
        photos[1].title = "Z"
        XCTAssertEqual(catalog.items(from: photos, query: byTitle).map(\.title), ["B", "Z"])
        let gif = Wallpaper(title: "Animation", kind: .gif, source: .local(filename: "a.gif"))
        photos.append(gif)
        let onlyGIFs = LibraryQuery(filter: .gifs)
        XCTAssertEqual(catalog.items(from: photos, query: onlyGIFs).map(\.id), [gif.id])
        photos.removeLast()
        XCTAssertTrue(catalog.items(from: photos, query: onlyGIFs).isEmpty)
        XCTAssertEqual(catalog.items(from: photos, query: LibraryQuery(text: "Z")).map(\.id), [photos[1].id])
        XCTAssertEqual(photos.map(\.title), ["B", "Z"])
    }
}
