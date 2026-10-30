import Foundation
import Testing
@testable import WallmotionCore

@Suite("Library filters and ordering")
struct LibraryQueryTests {
    private func item(_ number: Int, title: String, kind: MediaKind, source: MediaSource, date: Double) -> Wallpaper {
        Wallpaper(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!, title: title, kind: kind, source: source, addedAt: Date(timeIntervalSince1970: date))
    }
    private func items() throws -> [Wallpaper] {
        [item(1, title: "Praia 10", kind: .image, source: .local(filename: "photo.png"), date: 10),
         item(2, title: "Praia 2", kind: .video, source: .local(filename: "video.mp4"), date: 30),
         item(3, title: "Animação", kind: .gif, source: .local(filename: "animated.gif"), date: 20),
         item(4, title: "Oceano", kind: .video, source: .remote(url: URL(string: "https://example.com/video.mp4")!), date: 40),
         item(5, title: "Vídeo YouTube", kind: .video, source: .web(embed: try WebEmbed.parse("https://youtu.be/M7lc1UVf-VE")), date: 50)]
    }
    @Test func filtersDistinguishWebFromLocalAndDirectVideos() throws {
        let source = try items()
        #expect(LibraryQuery(filter: .all).items(from: source).count == 5)
        #expect(LibraryQuery(filter: .photos).items(from: source).map(\.id) == [source[0].id])
        #expect(LibraryQuery(filter: .gifs).items(from: source).map(\.id) == [source[2].id])
        #expect(Set(LibraryQuery(filter: .videos).items(from: source).map(\.id)) == Set([source[1].id, source[3].id]))
        #expect(LibraryQuery(filter: .web).items(from: source).map(\.id) == [source[4].id])
    }
    @Test func queryCombinesFilterWithTrimmedCaseAndAccentInsensitiveTitle() throws {
        let source = try items()
        #expect(LibraryQuery(text: "  ANIMACAO\n", filter: .gifs).items(from: source).map(\.id) == [source[2].id])
        #expect(LibraryQuery(text: "praia", filter: .videos).items(from: source).map(\.id) == [source[1].id])
        #expect(LibraryQuery(text: "missing").items(from: source).isEmpty)
        #expect(LibraryQuery(text: "   ").items(from: source).count == 5)
    }
    @Test func recentTitleAndTypeHaveDeterministicTieBreaks() throws {
        let source = try items()
        #expect(LibraryQuery(sort: .recent).items(from: source).map(\.id) == [4,3,1,2,0].map { source[$0].id })
        #expect(LibraryQuery(sort: .title).items(from: source).map(\.id) == [2,3,1,0,4].map { source[$0].id })
        #expect(LibraryQuery(sort: .mediaType).items(from: source).map(\.id) == [0,2,3,1,4].map { source[$0].id })
        var tied = Array(source.prefix(2))
        tied[1].addedAt = tied[0].addedAt
        tied[1].title = tied[0].title
        for sort in LibrarySortOrder.allCases {
            let forward = LibraryQuery(sort: sort).items(from: tied).map(\.id)
            let backward = LibraryQuery(sort: sort).items(from: tied.reversed()).map(\.id)
            #expect(forward == backward)
        }
    }
    @Test func projectionDoesNotChangeStoredOrderOrAppliedSelections() throws {
        let source = try items()
        let state = LibraryState(wallpapers: source, assignments: ["left": source[0].id])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let bytes = try encoder.encode(state)
        _ = LibraryQuery(text: "Oceano", filter: .videos, sort: .title).items(from: state.wallpapers)
        #expect(state.wallpapers == source)
        #expect(state.assignments == ["left": source[0].id])
        #expect(try encoder.encode(state) == bytes)
    }
}
