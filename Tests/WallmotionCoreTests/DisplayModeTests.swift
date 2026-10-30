import Foundation
import Testing
@testable import WallmotionCore

@Suite("Display mode and audio persistence")
struct DisplayModeTests {
    @Test(arguments: [1, 2, 3])
    func legacyJSONMigratesOnlyInMemory(_ version: Int) throws {
        let json = """
        {"version":\(version),"wallpapers":[{"id":"11111111-1111-1111-1111-111111111111","title":"Old","kind":"image","source":{"local":{"filename":"old.png"}},"addedAt":0}],"assignments":{"offline":"11111111-1111-1111-1111-111111111111"},"settings":{"pauseOnLowPower":false,"isManuallyPaused":true},"mediaFits":{"offline":{"11111111-1111-1111-1111-111111111111":"fill"}}}
        """
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = LibraryStore(rootURL: directory)
        let bytes = Data(json.utf8)
        try bytes.write(to: store.stateURL)
        let state = try store.load()
        #expect(state.version == 4)
        #expect(state.displayMode == .independent)
        #expect(state.mirroredWallpaperID == nil)
        #expect(state.mirroredMediaFit == .fit)
        #expect(state.settings.audioDisplayID == nil)
        #expect(!state.settings.pauseOnLowPower)
        #expect(state.settings.isManuallyPaused)
        #expect(state.mediaFit(for: state.wallpapers[0].id, on: "offline") == .fill)
        #expect(state.assignments["offline"] == state.wallpapers[0].id)
        #expect(try Data(contentsOf: store.stateURL) == bytes)
    }

    @Test func mirrorRoundTripAndRestorationPreserveIndependentChoices() throws {
        let one = try Wallpaper.remote("https://example.com/one.mp4")
        let two = try Wallpaper.remote("https://example.com/two.mp4")
        var state = LibraryState(wallpapers: [one, two], assignments: ["one": one.id, "offline": two.id],
                                 settings: .init(audioDisplayID: "offline"))
        state.setMediaFit(.fill, for: one.id, on: "one")
        let independent = state
        state.displayMode = .mirrored
        state.mirroredWallpaperID = two.id
        state.setMediaFit(.fit, for: two.id, on: "one")
        #expect(state.effectiveAssignments(for: ["one", "two", "one"]) == ["one": two.id, "two": two.id])
        #expect(state.mediaFit(for: two.id, on: "two") == .fit)
        state = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state)).validated()
        #expect(state.settings.audioDisplayID == "offline")
        state.mirroredWallpaperID = nil
        #expect(state.effectiveAssignments(for: ["one", "two"]).isEmpty)
        state.displayMode = .independent
        #expect(state.assignments == independent.assignments)
        #expect(state.mediaFits == independent.mediaFits)
        #expect(state.effectiveAssignments(for: ["one"]) == ["one": one.id])
        #expect(state.mediaFit(for: one.id, on: "one") == .fill)
    }

    @Test func removalAndValidationIncludeInactiveMirrorReference() throws {
        let item = try Wallpaper.remote("https://example.com/one.mp4")
        var state = LibraryState(wallpapers: [item], assignments: ["one": item.id], mirroredWallpaperID: item.id)
        state.remove(id: item.id)
        #expect(state.mirroredWallpaperID == nil)
        #expect(state.assignments.isEmpty)
        #expect(try state.validated() == state)
        state.mirroredWallpaperID = UUID()
        #expect(throws: LibraryError.invalidState) { try state.validated() }
        #expect(throws: LibraryError.invalidState) {
            try LibraryState(settings: .init(audioDisplayID: "")).validated()
        }
        #expect(try LibraryState(settings: .init(audioDisplayID: "offline")).validated().settings.audioDisplayID == "offline")
    }

    @Test(arguments: [2, 3, 4])
    func webSourcesRemainValid(_ version: Int) throws {
        let web = try Wallpaper.web("https://youtu.be/M7lc1UVf-VE")
        let state = try LibraryState(version: version, wallpapers: [web]).validated()
        #expect(state.version == 4)
        #expect(state.wallpapers == [web])
    }

    @Test func partialLegacySettingsUseSafeDefaults() throws {
        let settings = try JSONDecoder().decode(PlaybackSettings.self, from: Data("{}".utf8))
        #expect(settings == PlaybackSettings())
    }
}
