import Foundation
import Testing
@testable import WallmotionCore

@Suite("HLS resolution preferences")
struct HLSResolutionTests {
    @Test func legacySettingsDefaultToUnrestrictedAutomatic() throws {
        let settings = try JSONDecoder().decode(PlaybackSettings.self, from: Data("{}".utf8))
        #expect(settings.hlsResolution == .automatic)
        #expect(settings.hlsResolution.maximumDimensions == nil)
    }

    @Test(arguments: HLSResolution.allCases)
    func profilesRoundTripWithoutChangingAssignmentsOrAudio(_ resolution: HLSResolution) throws {
        let item = try Wallpaper.remote("https://cdn.example.com/live.m3u8")
        let state = LibraryState(wallpapers: [item], assignments: ["left": item.id], settings: .init(audioDisplayID: "left", audioVolume: 0.3, hlsResolution: resolution))
        let restored = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state)).validated()
        #expect(restored == state)
    }

    @Test func unsupportedPreferenceRejectsRatherThanSilentlyOverwriting() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PlaybackSettings.self, from: Data("{\"hlsResolution\":\"unknown-profile\"}".utf8))
        }
    }
}
