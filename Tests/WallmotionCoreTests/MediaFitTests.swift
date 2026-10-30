import Foundation
import CoreGraphics
import Testing
@testable import WallmotionCore

@Suite("Proportional media presentation")
struct MediaFitTests {
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
        for fit in MediaFit.allCases {
            #expect(fit.frame(for: CGSize(width: 3840, height: 2160), in: bounds) == bounds)
        }
    }

    @Test func decodeBudgetAccountsForCropAndNeverUpsamples() {
        let wide = CGSize(width: 8000, height: 2000)
        let retina = CGSize(width: 2000, height: 2000)
        #expect(MediaFit.fit.decodePixelLimit(for: wide, viewport: retina) == 2000)
        #expect(MediaFit.fill.decodePixelLimit(for: wide, viewport: retina) == 8000)
        #expect(MediaFit.fill.decodePixelLimit(for: CGSize(width: 64, height: 32), viewport: retina) == 64)
    }

    @Test func legacyVersionOneDefaultsToFit() throws {
        // Literal fixture with no new field; does not rely on today's encoder.
        let json = #"{"version":1,"wallpapers":[{"id":"11111111-1111-1111-1111-111111111111","title":"Old photo","kind":"image","source":{"local":{"filename":"old.png"}},"addedAt":0}],"assignments":{"display":"11111111-1111-1111-1111-111111111111"},"settings":{"pauseOnLowPower":true,"isManuallyPaused":false}}"#
        let state = try JSONDecoder().decode(LibraryState.self, from: Data(json.utf8)).validated()
        #expect(state.version == 1)
        #expect(state.mediaFits.isEmpty)
        #expect(state.mediaFit(for: state.wallpapers[0].id, on: "display") == .fit)
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
