import Foundation
import Testing
@testable import WallmotionCore

@Suite("Media validation")
struct MediaValidationTests {
    @Test(arguments: ["jpg", "JPEG", "png", "HEIC", "heif", "tiff", "tif", "bmp"])
    func recognizesPhotos(extension suffix: String) throws {
        #expect(try MediaKind.classify(fileURL: URL(fileURLWithPath: "/photo.\(suffix)")) == .image)
    }

    @Test(arguments: ["mp4", "MOV", "m4v"])
    func recognizesVideos(extension suffix: String) throws {
        #expect(try MediaKind.classify(fileURL: URL(fileURLWithPath: "/movie.\(suffix)")) == .video)
    }

    @Test func recognizesAnimatedGIF() throws {
        #expect(try MediaKind.classify(fileURL: URL(fileURLWithPath: "/animated.GIF")) == .gif)
    }

    @Test(arguments: ["/movie.webm", "/document.pdf", "/image", "/video.mp4.exe"])
    func rejectsUnsupportedFiles(_ path: String) {
        #expect(throws: LibraryError.unsupportedFile) {
            try MediaKind.classify(fileURL: URL(fileURLWithPath: path))
        }
    }

    @Test(arguments: [
        "https://cdn.example.com/movie.mp4",
        "https://cdn.example.com/movie.mov",
        "https://cdn.example.com/movie.m4v",
        "https://cdn.example.com/movie.webm",
        "https://cdn.example.com/live/master.m3u8?token=signed%2Fvalue&expires=123",
        "https://cdn.example.com/playback?id=123&signature=a%2Bb",
        "https://cdn.example.com/"
    ])
    func acceptsDirectAndExtensionlessMedia(_ value: String) throws {
        #expect(try MediaURL.validate(value).absoluteString == value)
    }

    @Test func trimsPastedURL() throws {
        #expect(try MediaURL.validate(" \nhttps://cdn.example.com/video.mp4\t").absoluteString == "https://cdn.example.com/video.mp4")
    }

    @Test(arguments: [
        "", "  ", "http://example.com/movie.mp4", "file:///tmp/video.mp4",
        "ftp://example.com/movie.mp4", "https:///", "/relative/movie.mp4",
        "https://user@example.com/video.mp4", "https://user:secret@example.com/video.mp4",
        "https://example.com/a b.mp4", "https://example.com/a\nb.mp4"
    ])
    func rejectsInvalidURLs(_ value: String) {
        #expect(throws: LibraryError.invalidURL) { try MediaURL.validate(value) }
    }

    @Test(arguments: [
        "https://youtube.com/watch?v=123", "https://www.YouTube.com/watch?v=123",
        "https://youtube-nocookie.com/embed/M7lc1UVf-VE",
        "https://www.YouTube-NoCookie.com/embed/M7lc1UVf-VE",
        "https://youtu.be/123", "https://player.vimeo.com/video/123",
        "https://dailymotion.com/video/123", "https://www.twitch.tv/channel",
        "https://example.com/watch.HTML", "https://example.com/watch.php?id=123",
        "https://example.com/watch.htm", "https://example.com/watch.asp",
        "https://example.com/watch.aspx"
    ])
    func rejectsKnownWebPages(_ value: String) {
        #expect(throws: LibraryError.webPageURL) { try MediaURL.validate(value) }
    }

    @Test func hostBlocklistUsesDomainBoundaries() throws {
        #expect(try MediaURL.validate("https://notyoutube.com/video.mp4").host == "notyoutube.com")
        #expect(try MediaURL.validate("https://notyoutube-nocookie.com/video.mp4").host == "notyoutube-nocookie.com")
    }

    @Test func newDirectSourceStillRejectsNoCookieEmbed() {
        #expect(throws: LibraryError.webPageURL) {
            try Wallpaper.remote("https://www.youtube-nocookie.com/embed/M7lc1UVf-VE")
        }
    }

    @Test(arguments: [
        "http://cdn.example.com/video.mp4", "https://user:secret@cdn.example.com/video.mp4",
        "https://youtube.com/watch?v=M7lc1UVf-VE", "https://vimeo.com/76979871",
        "https://cdn.example.com/page.html"
    ]) func persistedRemoteSourcesStillRejectPreviouslyInvalidURLs(_ text: String) throws {
        let item = Wallpaper(title: "Invalid", kind: .video, source: .remote(url: try #require(URL(string: text))))
        #expect(throws: (any Error).self) { try LibraryState(wallpapers: [item]).validated() }
        #expect(throws: (any Error).self) { try LibraryStore().resolvedURL(for: item) }
    }

    @Test func remoteWallpaperHasVideoKindAndPreservesSignedURL() throws {
        let value = "https://cdn.example.com/live.m3u8?token=abc%2Fdef"
        let item = try Wallpaper.remote(value)
        #expect(item.kind == .video)
        #expect(item.title == "live.m3u8")
        #expect(item.source == .remote(url: URL(string: value)!))
    }

    @Test func rootRemoteURLUsesHostnameAsTitle() throws {
        let item = try Wallpaper.remote("https://cdn.example.com/")
        #expect(item.title == "cdn.example.com")
    }
}
