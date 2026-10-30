import Foundation
import CoreGraphics
import Testing
@testable import WallmotionCore

@Suite("Proportional media presentation")
struct MediaFitTests {
    @Test func centerUsesOriginalPixelsAtBackingScaleAndStretchUsesBounds() {
        let source = CGSize(width: 800, height: 400)
        let bounds = CGRect(x: 10, y: 20, width: 100, height: 100)
        #expect(MediaFit.center.frame(for: source, in: bounds, backingScale: 2) == CGRect(x: -140, y: -30, width: 400, height: 200))
        #expect(MediaFit.stretch.frame(for: source, in: bounds) == bounds)
        #expect(MediaFit.center.decodePixelLimit(for: source, viewport: CGSize(width: 100, height: 100)) == 800)
    }

    @Test func landscapeFitAndFillAreCenteredWithoutStretching() {
        let media = CGSize(width: 400, height: 200)
        let bounds = CGRect(x: 10, y: 20, width: 100, height: 100)
        #expect(MediaFit.fit.frame(for: media, in: bounds) == CGRect(x: 10, y: 45, width: 100, height: 50))
        #expect(MediaFit.fill.frame(for: media, in: bounds) == CGRect(x: -40, y: 20, width: 200, height: 100))
    }

    @Test func portraitFitAndFillAreCenteredWithoutStretching() {
        let media = CGSize(width: 200, height: 400)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(MediaFit.fit.frame(for: media, in: bounds) == CGRect(x: 25, y: 0, width: 50, height: 100))
        #expect(MediaFit.fill.frame(for: media, in: bounds) == CGRect(x: 0, y: -50, width: 100, height: 200))
        #expect(MediaFit.fill.frame(for: .zero, in: bounds) == .zero)
        #expect(MediaFit.fit.frame(for: media, in: .zero) == .zero)
    }

    @Test func equalAspectRatiosUseSameFrame() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        for fit in [MediaFit.fit, .fill, .stretch] {
            #expect(fit.frame(for: CGSize(width: 3840, height: 2160), in: bounds) == bounds)
        }
    }

    @Test func decodeBudgetAccountsForCropAndNeverUpsamples() {
        let wide = CGSize(width: 8000, height: 2000)
        let retina = CGSize(width: 2000, height: 2000)
        #expect(MediaFit.fit.decodePixelLimit(for: wide, viewport: retina) == 2000)
        let fill = MediaFit.fill.decodePixelLimit(for: wide, viewport: retina)
        #expect(fill < 8000)
        #expect(PhotoDecodeBudget.estimatedBytes(for: wide, pixelLimit: fill) <= PhotoDecodeBudget.maximumBytes)
        #expect(MediaFit.fill.decodePixelLimit(for: CGSize(width: 64, height: 32), viewport: retina) == 64)
    }

    @Test func extremeReviewFixturesStayWithinByteBudgetWithoutAllocatingBitmaps() {
        let fixtures: [(CGSize, CGSize)] = [
            (CGSize(width: 6000, height: 60000), CGSize(width: 6000, height: 4000)),
            (CGSize(width: 60000, height: 2000), CGSize(width: 3840, height: 2160)),
            (CGSize(width: 60000, height: 6000), CGSize(width: 4000, height: 6000)),
            (CGSize(width: 1, height: 1_000_000_000), CGSize(width: 6000, height: 4000)),
            (CGSize(width: 1_000_000_000, height: 1), CGSize(width: 6000, height: 4000))
        ]
        for (source, viewport) in fixtures {
            for fit in MediaFit.allCases {
                let edge = fit.decodePixelLimit(for: source, viewport: viewport)
                #expect((1...16_384).contains(edge))
                // Independently account for upward rounding and conservative 16 B/px,
                // including row padding. No image/decoder or pixel buffer is allocated.
                let scale = min(1, Double(edge) / max(source.width, source.height))
                let width = max(1, Int(ceil(source.width * scale)))
                let height = max(1, Int(ceil(source.height * scale)))
                let bytes = ((width * 16 + 63) / 64) * 64 * height
                #expect(bytes <= 128 * 1024 * 1024)
            }
            #expect(MediaFit.fill.decodePixelLimit(for: source, viewport: viewport) < Int(max(source.width, source.height)))
        }
    }

    @Test func budgetBoundaryIsEnforcedAndRetinaQualitySurvivesWithinBudget() {
        let source = CGSize(width: 7680, height: 4320)
        let retina = CGSize(width: 3840, height: 2160)
        for fit in [MediaFit.fit, .fill, .stretch] {
            #expect(fit.decodePixelLimit(for: source, viewport: retina) == 3840)
        }
        let square = CGSize(width: 60000, height: 60000)
        let edge = MediaFit.fill.decodePixelLimit(for: square, viewport: square)
        #expect(PhotoDecodeBudget.estimatedBytes(for: square, pixelLimit: edge) <= PhotoDecodeBudget.maximumBytes)
        #expect(PhotoDecodeBudget.estimatedBytes(for: square, pixelLimit: edge + 1) > PhotoDecodeBudget.maximumBytes)
    }

    @Test func invalidAndOverflowingDimensionsNeverOverflowIntegerConversion() {
        let viewport = CGSize(width: 3840, height: 2160)
        for fit in MediaFit.allCases {
            for invalid in [CGFloat.nan, .infinity, -1, 0] {
                #expect(fit.decodePixelLimit(for: CGSize(width: invalid, height: 100), viewport: viewport) == 1)
                #expect(fit.decodePixelLimit(for: viewport, viewport: CGSize(width: invalid, height: 100)) == 1)
            }
            let huge = CGSize(width: CGFloat.greatestFiniteMagnitude, height: 1)
            let limit = fit.decodePixelLimit(for: huge, viewport: viewport)
            #expect((1...PhotoDecodeBudget.maximumDimension).contains(limit))
            #expect(PhotoDecodeBudget.estimatedBytes(for: huge, pixelLimit: limit) <= PhotoDecodeBudget.maximumBytes)
        }
    }

    @Test func legacyVersionOneDefaultsToFit() throws {
        // Literal fixture with no new field; does not rely on today's encoder.
        let json = #"{"version":1,"wallpapers":[{"id":"11111111-1111-1111-1111-111111111111","title":"Old photo","kind":"image","source":{"local":{"filename":"old.png"}},"addedAt":0}],"assignments":{"display":"11111111-1111-1111-1111-111111111111"},"settings":{"pauseOnLowPower":true,"isManuallyPaused":false}}"#
        let state = try JSONDecoder().decode(LibraryState.self, from: Data(json.utf8)).validated()
        #expect(state.version == 4)
        #expect(state.mediaFits.isEmpty)
        #expect(state.mediaFit(for: state.wallpapers[0].id, on: "display") == .fit)
    }

    @Test func legacyRemoteAndSavedFillSurviveVersionTwoMigration() throws {
        // Persistence-only fixture: no network or playback certification.
        let json = #"{"version":1,"wallpapers":[{"id":"11111111-1111-1111-1111-111111111111","title":"Legacy remote","kind":"video","source":{"remote":{"url":"https://www.youtube-nocookie.com/embed/M7lc1UVf-VE"}},"addedAt":0}],"assignments":{"display":"11111111-1111-1111-1111-111111111111"},"settings":{"pauseOnLowPower":true,"isManuallyPaused":true},"mediaFits":{"display":{"11111111-1111-1111-1111-111111111111":"fill"}}}"#
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = LibraryStore(rootURL: root)
        let bytes = Data(json.utf8)
        try bytes.write(to: store.stateURL)
        let loaded = try store.load()
        let item = try #require(loaded.wallpapers.first)
        #expect(loaded.version == 4)
        #expect(loaded.mediaFit(for: item.id, on: "display") == .fill)
        #expect(loaded.mediaFit(for: item.id, on: "other") == .fit)
        #expect(item.source == .remote(url: URL(string: "https://www.youtube-nocookie.com/embed/M7lc1UVf-VE")!))
        #expect(loaded.assignments["display"] == item.id)
        #expect(loaded.settings.isManuallyPaused)
        #expect(try Data(contentsOf: store.stateURL) == bytes)
        try store.save(loaded)
        #expect(try store.load() == loaded)
    }

    @Test func preferencesRoundTripByWallpaperAndDisplayAndAreRemovedWithMedia() throws {
        let first = try Wallpaper.remote("https://example.com/first.mp4")
        let second = try Wallpaper.remote("https://example.com/second.mp4")
        var state = LibraryState(wallpapers: [first, second], assignments: ["one": first.id, "two": first.id])
        state.setMediaFit(.fill, for: first.id, on: "one")
        state.setMediaFit(.fit, for: second.id, on: "one")
        #expect(state.mediaFit(for: first.id, on: "two") == .fit)
        state.assignments["one"] = second.id
        #expect(state.mediaFit(for: second.id, on: "one") == .fit)
        state.assignments["one"] = first.id
        #expect(state.mediaFit(for: first.id, on: "one") == .fill)
        let decoded = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state)).validated()
        #expect(decoded == state)
        state.remove(id: first.id)
        #expect(state.mediaFits["one"] == [second.id.uuidString: .fit])
        state.remove(id: second.id)
        #expect(state.mediaFits.isEmpty)
    }

    @Test func rejectsDanglingMediaPreferences() throws {
        let item = try Wallpaper.remote("https://example.com/movie.mp4")
        var state = LibraryState(wallpapers: [item])
        state.setMediaFit(.fill, for: UUID(), on: "display")
        #expect(throws: LibraryError.invalidState) { try state.validated() }
    }
}
