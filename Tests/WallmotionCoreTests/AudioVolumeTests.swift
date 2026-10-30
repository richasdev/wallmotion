import Foundation
import Testing
@testable import WallmotionCore

@Suite("Audio volume persistence")
struct AudioVolumeTests {
    @Test func legacySettingsKeepMutedDefaultAndOriginalGain() throws {
        let settings = try JSONDecoder().decode(PlaybackSettings.self, from: Data("{\"pauseOnLowPower\":true,\"isManuallyPaused\":false}".utf8))
        #expect(settings.audioVolume == 1)
        #expect(settings.audioDisplayID == nil)
    }

    @Test func volumeRoundTripsWithoutChangingDisplayAssignments() throws {
        let item = try Wallpaper.remote("https://cdn.example.com/video.mp4")
        let state = LibraryState(wallpapers: [item], assignments: ["left": item.id], settings: .init(audioDisplayID: "left", audioVolume: 0.25))
        let restored = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state)).validated()
        #expect(restored == state)
        #expect(restored.settings.audioVolume == 0.25)
        #expect(restored.assignments == ["left": item.id])
    }

    @Test(arguments: [-1.0, 1.01, Double.nan, Double.infinity, -Double.infinity])
    func invalidGainCannotReachPlayback(_ volume: Double) {
        let state = LibraryState(settings: .init(audioVolume: volume))
        #expect(throws: LibraryError.invalidState) { try state.validated() }
    }

    @Test(arguments: [0.0, 0.01, 0.5, 1.0]) func validGainSurvivesValidation(_ volume: Double) throws {
        let state = LibraryState(settings: .init(audioVolume: volume))
        #expect(try state.validated().settings.audioVolume == volume)
    }
}
