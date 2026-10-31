import Foundation
import Testing
@testable import WallmotionCore

@Suite("Native visual panorama geometry and persistence")
struct PanoramaLayoutTests {
    @Test func globalCoordinatesKeepSeamsAcrossNegativeOriginsAndMixedDPI() throws {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let right = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let layout = try #require(PanoramaLayout(frames: [left, right], backingScales: [1, 2]))
        #expect(layout.bounds == CGRect(x: -1920, y: 0, width: 3840, height: 1080))
        #expect(layout.pixelSize == CGSize(width: 7680, height: 2160))
        let pixels = CGSize(width: 7680, height: 2160)
        for fit in MediaFit.allCases {
            let a = layout.imageFrame(sourcePixels: pixels, fit: fit, on: left)
            let b = layout.imageFrame(sourcePixels: pixels, fit: fit, on: right)
            #expect(a.offsetBy(dx: left.minX, dy: left.minY) == b.offsetBy(dx: right.minX, dy: right.minY))
            #expect(a.width == 3840)
        }
    }

    @Test func verticalGapsAndAllFitsUseOneUnion() throws {
        let bottom = CGRect(x: -100, y: -300, width: 200, height: 100)
        let top = CGRect(x: 0, y: 0, width: 100, height: 200)
        let layout = try #require(PanoramaLayout(frames: [bottom, top], backingScales: [2, 1]))
        #expect(layout.bounds == CGRect(x: -100, y: -300, width: 200, height: 500))
        let source = CGSize(width: 800, height: 400)
        // Shared 2x reference makes center 400 × 200 points on every screen.
        let center = layout.imageFrame(sourcePixels: source, fit: .center, on: bottom)
        #expect(center == CGRect(x: -100, y: 150, width: 400, height: 200))
        let fit = layout.imageFrame(sourcePixels: source, fit: .fit, on: bottom)
        #expect(fit == CGRect(x: 0, y: 200, width: 200, height: 100))
        let fill = layout.imageFrame(sourcePixels: source, fit: .fill, on: bottom)
        #expect(fill == CGRect(x: -400, y: 0, width: 1000, height: 500))
        #expect(layout.imageFrame(sourcePixels: source, fit: .stretch, on: top) == CGRect(x: -100, y: -300, width: 200, height: 500))
    }

    @Test func invalidAndOverflowingGeometryIsRejected() {
        let valid = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(PanoramaLayout(frames: [], backingScales: []) == nil)
        #expect(PanoramaLayout(frames: [valid], backingScales: []) == nil)
        for scale in [CGFloat.zero, -1, .infinity, .nan, .greatestFiniteMagnitude] {
            #expect(PanoramaLayout(frames: [valid], backingScales: [scale]) == nil)
        }
        for frame in [CGRect.zero, CGRect.infinite, CGRect(x: CGFloat.infinity, y: 0, width: 1, height: 1), CGRect(x: 0, y: 0, width: CGFloat.nan, height: 1)] {
            #expect(PanoramaLayout(frames: [frame], backingScales: [1]) == nil)
        }
    }

    @Test func panoramaRoundTripPreservesIndependentChoicesAndAllowsNativeVideo() throws {
        let photo = Wallpaper(title: "Photo", kind: .image, source: .local(filename: "photo.png"))
        let video = try Wallpaper.remote("https://example.com/video.mp4")
        var state = LibraryState(wallpapers: [photo, video], assignments: ["left": video.id, "offline": photo.id], displayMode: .spanned, mirroredWallpaperID: photo.id, mirroredMediaFit: .fill)
        state.mediaFits = ["left": [video.id.uuidString: .stretch]]
        let restored = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state)).validated()
        #expect(restored == state)
        #expect(restored.effectiveAssignments(for: ["left", "new"]) == ["left": photo.id, "new": photo.id])
        #expect(restored.mediaFit(for: photo.id, on: "new") == .fill)
        state.displayMode = .independent
        #expect(state.effectiveAssignments(for: ["left"]) == ["left": video.id])
        #expect(state.mediaFit(for: video.id, on: "left") == .stretch)
        state.displayMode = .spanned
        state.mirroredWallpaperID = video.id
        #expect(try state.validated().mirroredWallpaperID == video.id)
        state.mirroredWallpaperID = nil
        #expect(try state.validated().effectiveAssignments(for: ["left"]).isEmpty)
    }
    @Test func localGIFPanoramaPersistsAndWebOrRemoteImagesStayIneligible() throws {
        let gif = Wallpaper(title: "Animation", kind: .gif, source: .local(filename: "animation.gif"))
        var state = LibraryState(wallpapers: [gif], assignments: ["offline": gif.id], displayMode: .spanned,
            mirroredWallpaperID: gif.id, mirroredMediaFit: .center)
        let restored = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state)).validated()
        #expect(restored == state)
        #expect(restored.effectiveAssignments(for: ["left", "right"]) == ["left": gif.id,"right": gif.id])
        #expect(restored.mediaFit(for: gif.id, on: "left") == .center)
        for item in [Wallpaper(title: "Remote GIF", kind: .gif, source: .remote(url: URL(string: "https://example.com/a.gif")!)),
                     try Wallpaper.web("https://youtu.be/M7lc1UVf-VE")] {
            #expect(!item.supportsPanorama)
            state.wallpapers = [item];state.assignments = [:];state.mirroredWallpaperID = item.id
            #expect(throws: LibraryError.invalidState) { try state.validated() }
        }
    }
    @Test func localAndRemoteNativeVideoPersistInPanorama() throws {
        for item in [Wallpaper(title: "Local",kind: .video,source: .local(filename: "video.mp4")),
                     try Wallpaper.remote("https://example.com/video.m3u8")] {
            #expect(item.supportsPanorama)
            let state = LibraryState(wallpapers: [item],displayMode: .spanned,mirroredWallpaperID: item.id)
            #expect(try JSONDecoder().decode(LibraryState.self,from: JSONEncoder().encode(state)).validated() == state)
        }
    }

}
