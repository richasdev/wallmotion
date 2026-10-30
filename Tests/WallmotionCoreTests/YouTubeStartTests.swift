import Foundation
import Testing
@testable import WallmotionCore

@Suite("YouTube start positions")
struct YouTubeStartTests {
    @Test(arguments: [
        ("https://youtu.be/M7lc1UVf-VE?t=90&list=ignored", 90),
        ("https://www.youtube.com/watch?v=M7lc1UVf-VE&t=1h2m3s", 3723),
        ("https://www.youtube.com/watch?v=M7lc1UVf-VE&start=90", 90),
        ("https://www.youtube-nocookie.com/embed/M7lc1UVf-VE?start=12", 12),
        ("https://youtube.com/shorts/M7lc1UVf-VE?t=0s", 0),
        ("https://youtu.be/M7lc1UVf-VE#t=45s", 45),
        ("https://m.youtube.com/live/M7lc1UVf-VE?t=2m", 120),
        ("https://youtu.be/M7lc1UVf-VE?t=2147483647", Int(Int32.max))
    ])
    func normalizesAndRoundTripsStart(_ text: String, _ expected: Int) throws {
        let embed = try WebEmbed.parse(text)
        #expect(embed.startSeconds == expected)
        #expect(try WebEmbed.parse(embed.pageURL.absoluteString) == embed)
        #expect(try JSONDecoder().decode(WebEmbed.self, from: JSONEncoder().encode(embed)) == embed)
    }

    @Test(arguments: [
        "t=90&t=91", "t=90&start=90", "t=90#t=90", "t", "t=", "start=1m",
        "t=-1", "t=%2B1", "t=90.5", "t=1s1m", "t=1m2m", "t=1h2", "t=1M",
        "t=2147483648", "t=99999999999999999999999999999999999", "t=1h999999999m",
        "t=%D9%A1", "t=1%00s", "start=90&start=90", "t=0&start"
    ])
    func rejectsAmbiguousMalformedAndOverflowingTimes(_ query: String) {
        #expect(throws: LibraryError.unsupportedEmbed) { try WebEmbed.parse("https://youtu.be/M7lc1UVf-VE?" + query) }
    }

    @Test func legacyEmbedsStartAtZeroAndVimeoDoesNotAcceptYouTubeOffsets() throws {
        let legacy = try JSONDecoder().decode(WebEmbed.self, from: Data(#"{"provider":"youtube","videoID":"M7lc1UVf-VE"}"#.utf8))
        #expect(legacy.startSeconds == 0)
        #expect(legacy.pageURL.absoluteString == "https://www.youtube.com/watch?v=M7lc1UVf-VE")
        #expect(throws: LibraryError.unsupportedEmbed) { try WebEmbed(provider: .vimeo, videoID: "76979871", startSeconds: 5) }
        #expect(throws: LibraryError.unsupportedEmbed) { try WebEmbed(provider: .youtube, videoID: "M7lc1UVf-VE", startSeconds: -1) }
        let malformed = Data(#"{"provider":"youtube","videoID":"M7lc1UVf-VE","startSeconds":-1}"#.utf8)
        #expect(throws: LibraryError.unsupportedEmbed) { try JSONDecoder().decode(WebEmbed.self, from: malformed) }
    }

    @Test func initialTimeAppearsInTitleAndPersistsWithAssignments() throws {
        let wallpaper = try Wallpaper.web("https://youtu.be/M7lc1UVf-VE?t=1m30s")
        #expect(wallpaper.title.hasSuffix("1:30"))
        let state = LibraryState(wallpapers: [wallpaper], assignments: ["display": wallpaper.id])
        let restored = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state)).validated()
        #expect(restored == state)
        let long = try WebEmbed(provider: .youtube, videoID: "M7lc1UVf-VE", startSeconds: 3723)
        #expect(long.startTimeLabel == "1:02:03")
    }

    @Test func rejectsUnboundedURLBeforeParsingQuery() {
        let text = "https://youtu.be/M7lc1UVf-VE?tracking=" + String(repeating: "a", count: 4096)
        #expect(throws: LibraryError.unsupportedEmbed) { try WebEmbed.parse(text) }
    }
}
