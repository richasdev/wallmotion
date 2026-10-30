import Foundation
import Testing
@testable import WallmotionCore

struct WebEmbedTests {
    @Test(arguments: [
        "https://www.youtube.com/watch?v=M7lc1UVf-VE&t=30&list=ignored",
        " https://youtu.be/M7lc1UVf-VE?si=tracking\n",
        "https://m.youtube.com/shorts/M7lc1UVf-VE",
        "https://www.youtube-nocookie.com/embed/M7lc1UVf-VE",
        "https://www.youtube.com/live/M7lc1UVf-VE"
    ]) func normalizesYouTube(_ text: String) throws {
        let embed = try WebEmbed.parse(text)
        let expected = try WebEmbed(provider: .youtube, videoID: "M7lc1UVf-VE")
        #expect(embed == expected)
        #expect(embed.pageURL.absoluteString == "https://www.youtube.com/watch?v=M7lc1UVf-VE")
    }

    @Test func normalizesVimeoAndPreservesUnlistedHash() throws {
        let first = try WebEmbed.parse("https://vimeo.com/76979871/8272103f6e?share=copy")
        let playerURL = try WebEmbed.parse("https://player.vimeo.com/video/76979871?h=8272103f6e&autoplay=0")
        #expect(first == playerURL)
        let canonical = try WebEmbed.parse(first.pageURL.absoluteString)
        #expect(first == canonical)
        #expect(try WebEmbed.parse("https://vimeo.com/76979871").privacyHash == nil)
    }

    @Test(arguments: [
        "http://youtu.be/M7lc1UVf-VE", "https://user@youtu.be/M7lc1UVf-VE",
        "https://youtu.be:444/M7lc1UVf-VE", "https://youtube.com.evil.com/watch?v=M7lc1UVf-VE",
        "https://evil.youtube.com/watch?v=M7lc1UVf-VE", "https://youtube.com/playlist?list=abc",
        "https://youtube.com/watch?v=M7lc1UVf-VE&v=xxxxxxxxxxx", "https://youtu.be/short",
        "https://youtu.be/M7lc1UVf-VE/extra", "https://youtu.be/embed/M7lc1UVf-VE", "https://www.youtube-nocookie.com/shorts/M7lc1UVf-VE", "https://vimeo.com/channels/123",
        "https://vimeo.com/0", "https://vimeo.com/123/%3Cscript%3E",
        "https://player.vimeo.com/video/123?h=a&h=b", "https://example.com/video.mp4",
        "https://accounts.google.com/login", "https://youtube.com/embed/%22%3E%3Cscript%3E"
    ]) func rejectsUnsupportedAndUnsafeURLs(_ text: String) {
        #expect(throws: LibraryError.unsupportedEmbed) { try WebEmbed.parse(text) }
    }

    @Test func migrationPreservesVersionOneBytesAndExistingSources() throws {
        // Literal v1 JSON freezes the old associated-value encoding contract.
        let bytes = Data("""
        {"version":1,"wallpapers":[{"id":"00000000-0000-0000-0000-000000000001","title":"Original","kind":"video","source":{"remote":{"url":"https://cdn.example.com/stream?token=a%2Fb"}},"addedAt":0},{"id":"00000000-0000-0000-0000-000000000002","title":"Local","kind":"image","source":{"local":{"filename":"photo.png"}},"addedAt":1}],"assignments":{"display":"00000000-0000-0000-0000-000000000001"},"settings":{"pauseOnLowPower":false,"isManuallyPaused":true}}
        """.utf8)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = LibraryStore(rootURL: root)
        try bytes.write(to: store.stateURL)
        var loaded = try store.load()
        #expect(loaded.version == 3)
        #expect(try Data(contentsOf: store.stateURL) == bytes)
        #expect(loaded.wallpapers[0].source == .remote(url: URL(string: "https://cdn.example.com/stream?token=a%2Fb")!))
        #expect(loaded.wallpapers[1].source == .local(filename: "photo.png"))
        #expect(loaded.settings == PlaybackSettings(pauseOnLowPower: false, isManuallyPaused: true))
        loaded.wallpapers.append(try Wallpaper.web("https://vimeo.com/76979871"))
        try store.save(loaded)
        #expect(try store.load() == loaded)
        #expect(loaded.assignments["display"] == loaded.wallpapers[0].id)
    }

    @Test func migrationPreservesLegacyNoCookieRemoteWithoutReclassification() throws {
        // Persistence compatibility only: no network or playback certification.
        let bytes = Data("""
        {"version":1,"wallpapers":[{"id":"00000000-0000-0000-0000-000000000001","title":"Legacy remote","kind":"video","source":{"remote":{"url":"https://www.youtube-nocookie.com/embed/M7lc1UVf-VE"}},"addedAt":0},{"id":"00000000-0000-0000-0000-000000000002","title":"Local photo","kind":"image","source":{"local":{"filename":"photo.png"}},"addedAt":1}],"assignments":{"remote-display":"00000000-0000-0000-0000-000000000001","photo-display":"00000000-0000-0000-0000-000000000002"},"settings":{"pauseOnLowPower":false,"isManuallyPaused":true}}
        """.utf8)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = LibraryStore(rootURL: root)
        try bytes.write(to: store.stateURL)
        var expected = try JSONDecoder().decode(LibraryState.self, from: bytes)
        expected.version = 2
        let loaded = try store.load()
        #expect(loaded == expected)
        #expect(try Data(contentsOf: store.stateURL) == bytes)
        let url = try #require(URL(string: "https://www.youtube-nocookie.com/embed/M7lc1UVf-VE"))
        #expect(loaded.wallpapers[0].source == .remote(url: url))
        #expect(try store.resolvedURL(for: loaded.wallpapers[0]) == url)
        // Compatibility must survive saving/reloading the migrated v2 too.
        var edited = loaded
        edited.wallpapers.append(try Wallpaper.remote("https://cdn.example.com/video.mp4"))
        try store.save(edited)
        #expect(try store.load() == edited)
        #expect(try store.resolvedURL(for: store.load().wallpapers[0]) == url)
    }

    @Test func decodedInvalidEmbedCannotReachRendererOrSave() throws {
        let malformed = Data(#"{"provider":"youtube","videoID":"<script>"}"#.utf8)
        let embed = try JSONDecoder().decode(WebEmbed.self, from: malformed)
        let item = Wallpaper(title: "Invalid", kind: .video, source: .web(embed: embed))
        #expect(throws: LibraryError.unsupportedEmbed) { try LibraryState(wallpapers: [item]).validated() }
        #expect(throws: LibraryError.unsupportedEmbed) { try LibraryStore().resolvedURL(for: item) }
        let valid = try Wallpaper.web("https://youtu.be/M7lc1UVf-VE")
        #expect(throws: LibraryError.invalidState) { try LibraryState(version: 1, wallpapers: [valid]).validated() }
    }
}
