import Foundation
import Testing
@testable import WallmotionCore

@Suite("Per-wallpaper audio gain")
struct AudioGainTests {
    @Test(arguments: [1, 2, 3, 4]) func legacyLibrariesDefaultToFullSourceLevel(_ version: Int) throws {
        let item = try Wallpaper.remote("https://cdn.example.com/video.mp4")
        let state = LibraryState(wallpapers: [item], assignments: ["left": item.id], settings: .init(audioDisplayID: "left", audioVolume: 0.5))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        json["audioGains"] = nil;json["version"] = version
        let restored = try JSONDecoder().decode(LibraryState.self, from: JSONSerialization.data(withJSONObject: json)).validated()
        #expect(restored.audioGains.isEmpty)
        #expect(restored.audioGain(for: item.id) == 1)
        #expect(restored.effectiveAudioVolume(for: item.id) == 0.5)
        #expect(restored.assignments == state.assignments)
    }

    @Test func sourceLevelsRoundTripComposeIndependentlyAndRemoveWithOnlyTheirItem() throws {
        let first = try Wallpaper.remote("https://cdn.example.com/video.mp4")
        let second = try Wallpaper.remote("https://cdn.example.com/video.mp4")
        var state = LibraryState(wallpapers: [first, second], settings: .init(audioVolume: 0.5))
        state.setAudioGain(0.2, for: first.id);state.setAudioGain(0.8, for: second.id)
        let restored = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state)).validated()
        #expect(restored == state)
        #expect(restored.effectiveAudioVolume(for: first.id) == 0.1)
        #expect(restored.effectiveAudioVolume(for: second.id) == 0.4)
        state.remove(id: first.id)
        #expect(state.audioGains[first.id.uuidString] == nil)
        #expect(state.audioGain(for: second.id) == 0.8)
        state.setAudioGain(1, for: second.id)
        #expect(state.audioGains.isEmpty)
        #expect(state.effectiveAudioVolume(for: second.id) == 0.5)
    }

    @Test(arguments: [-1.0, 1.01, Double.nan, Double.infinity, -Double.infinity])
    func invalidStoredLevelsAreRejectedAndCannotProduceAudio(_ level: Double) throws {
        let item = try Wallpaper.remote("https://cdn.example.com/video.mp4")
        let state = LibraryState(wallpapers: [item], audioGains: [item.id.uuidString: level])
        #expect(throws: LibraryError.invalidState) { try state.validated() }
        #expect(state.effectiveAudioVolume(for: item.id) == 0)
    }

    @Test func foreignAndSilentMediaPreferencesCannotReachStore() throws {
        let photo = Wallpaper(title: "Still", kind: .image, source: .local(filename: "still.png"))
        let gif = Wallpaper(title: "Animation", kind: .gif, source: .local(filename: "animation.gif"))
        for key in [photo.id.uuidString, gif.id.uuidString, UUID().uuidString, "not-an-id"] {
            let state = LibraryState(wallpapers: [photo, gif], audioGains: [key: 0.5])
            #expect(throws: LibraryError.invalidState) { try state.validated() }
        }
    }

    @Test func zeroGainAndZeroMasterBothMuteWithoutChangingOtherPreferences() throws {
        let item = try Wallpaper.remote("https://cdn.example.com/video.mp4")
        var state = LibraryState(wallpapers: [item], settings: .init(audioDisplayID: "left"))
        state.setAudioGain(0, for: item.id)
        #expect(try state.validated().effectiveAudioVolume(for: item.id) == 0)
        state.setAudioGain(0.5, for: item.id);state.settings.audioVolume = 0
        #expect(try state.validated().effectiveAudioVolume(for: item.id) == 0)
        #expect(state.audioGain(for: item.id) == 0.5)
        #expect(state.settings.audioDisplayID == "left")
    }
}
