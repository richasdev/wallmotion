import Foundation
import Testing
@testable import WallmotionCore

@Suite("Display preferences")
struct DisplayPreferencesTests {
    @Test func mirroredWallpaperFollowsConnectedDisplaysAndReturnsAfterReconnect() throws {
        let wallpaper = try Wallpaper.remote("https://cdn.example.com/wallpaper.mp4")
        let state = LibraryState(
            wallpapers: [wallpaper],
            displayMode: .mirrored,
            mirroredWallpaperID: wallpaper.id
        )

        #expect(state.effectiveAssignments(for: ["display-a", "display-b"]) == [
            "display-a": wallpaper.id,
            "display-b": wallpaper.id
        ])
        #expect(state.effectiveAssignments(for: ["display-a"]) == ["display-a": wallpaper.id])
        #expect(state.effectiveAssignments(for: ["display-a", "display-b"]) == [
            "display-a": wallpaper.id,
            "display-b": wallpaper.id
        ])
    }

    @Test func switchingBackToIndependentRestoresAssignmentsAndPerDisplayFits() throws {
        let first = try Wallpaper.remote("https://cdn.example.com/first.mp4")
        let second = try Wallpaper.remote("https://cdn.example.com/second.mp4")
        var state = LibraryState(
            wallpapers: [first, second],
            assignments: ["display-a": first.id, "display-b": second.id],
            displayMode: .independent
        )
        state.setMediaFit(.fill, for: first.id, on: "display-a")
        state.setMediaFit(.center, for: second.id, on: "display-b")
        state.displayMode = .mirrored
        state.mirroredWallpaperID = first.id

        #expect(state.effectiveAssignments(for: ["display-a", "display-b"]) == [
            "display-a": first.id,
            "display-b": first.id
        ])
        #expect(state.mediaFit(for: first.id, on: "display-b") == .fit)

        state.displayMode = .independent
        #expect(state.effectiveAssignments(for: ["display-a", "display-b"]) == [
            "display-a": first.id,
            "display-b": second.id
        ])
        #expect(state.mediaFit(for: first.id, on: "display-a") == .fill)
        #expect(state.mediaFit(for: second.id, on: "display-b") == .center)
    }

    @Test func rejectsStaleMirroredWallpaperReference() throws {
        let wallpaper = try Wallpaper.remote("https://cdn.example.com/wallpaper.mp4")
        let state = LibraryState(
            wallpapers: [wallpaper],
            displayMode: .mirrored,
            mirroredWallpaperID: UUID()
        )

        #expect(throws: LibraryError.invalidState) { try state.validated() }
    }

    @Test func removingMirroredWallpaperClearsMirrorReference() throws {
        let wallpaper = try Wallpaper.remote("https://cdn.example.com/wallpaper.mp4")
        var state = LibraryState(wallpapers: [wallpaper], displayMode: .mirrored, mirroredWallpaperID: wallpaper.id)

        state.remove(id: wallpaper.id)

        #expect(state.mirroredWallpaperID == nil)
        #expect(state.wallpapers.isEmpty)
        #expect(try state.validated() == state)
    }

    @Test func legacyVersionsMigrateToFourWithoutLosingIndependentPreferences() throws {
        let wallpaper = Wallpaper(title: "Legacy image", kind: .image, source: .local(filename: "legacy.png"))
        let settings = PlaybackSettings(pauseOnLowPower: false, isManuallyPaused: true)
        let original = LibraryState(
            version: 3,
            wallpapers: [wallpaper],
            assignments: ["display-a": wallpaper.id, "display-b": wallpaper.id],
            settings: settings,
            mediaFits: ["display-a": [wallpaper.id.uuidString: .fill], "display-b": [wallpaper.id.uuidString: .center]],
            displayMode: .independent
        )

        for legacyVersion in [1, 2, 3] {
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            object["version"] = legacyVersion
            object.removeValue(forKey: "displayMode")
            object.removeValue(forKey: "mirroredWallpaperID")
            object.removeValue(forKey: "mirroredMediaFit")
            var legacySettings = try #require(object["settings"] as? [String: Any])
            legacySettings.removeValue(forKey: "audioDisplayID")
            object["settings"] = legacySettings
            let legacyData = try JSONSerialization.data(withJSONObject: object)
            let migrated = try JSONDecoder().decode(LibraryState.self, from: legacyData).validated()

            #expect(migrated.version == 4)
            #expect(migrated.displayMode == .independent)
            #expect(migrated.mirroredWallpaperID == nil)
            #expect(migrated.assignments == original.assignments)
            #expect(migrated.mediaFits == original.mediaFits)
            #expect(migrated.settings == settings)
        }
    }

    @Test func actualLegacyJSONWithoutAudioKeyDefaultsToNoAudioDisplay() throws {
        let wallpaper = try Wallpaper.remote("https://cdn.example.com/wallpaper.mp4")
        let current = LibraryState(version: 3, wallpapers: [wallpaper], settings: .init(audioDisplayID: "display-a"))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        var settings = try #require(object["settings"] as? [String: Any])
        settings.removeValue(forKey: "audioDisplayID")
        object["settings"] = settings
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(LibraryState.self, from: legacyData).validated()

        #expect(decoded.settings.audioDisplayID == nil)
    }

    @Test func explicitAudioDisplaySurvivesRoundTripAndClearingMedia() throws {
        let wallpaper = try Wallpaper.remote("https://cdn.example.com/wallpaper.mp4")
        var state = LibraryState(
            wallpapers: [wallpaper],
            settings: .init(audioDisplayID: "display-b")
        )

        let decoded = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state)).validated()
        #expect(decoded.settings.audioDisplayID == "display-b")

        state.remove(id: wallpaper.id)

        #expect(state.settings.audioDisplayID == "display-b")
    }
}
