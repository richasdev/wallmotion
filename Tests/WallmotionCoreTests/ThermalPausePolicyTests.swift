import Foundation
import Testing
@testable import WallmotionCore

struct ThermalPausePolicyTests {
    @Test func hysteresisAndOptOut() {
        var thermal = ThermalPausePolicy()
        thermal.update(.fair, enabled: true)
        #expect(!thermal.isPaused)
        thermal.update(.serious, enabled: true)
        #expect(thermal.isPaused)
        thermal.update(.fair, enabled: true)
        #expect(thermal.isPaused)
        thermal.update(.nominal, enabled: true)
        #expect(!thermal.isPaused)
        thermal.update(.critical, enabled: true)
        #expect(thermal.isPaused)
        thermal.update(.critical, enabled: false)
        #expect(!thermal.isPaused)
        thermal.update(.fair, enabled: true)
        #expect(!thermal.isPaused)
    }

    @Test func thermalRecoveryDoesNotReleaseManualOrSystemPause() {
        var policy = PlaybackPolicy()
        policy.thermal.update(.critical, enabled: true)
        #expect(policy.isPaused(settings: .init(), lowPower: false))
        #expect(!policy.isPaused(settings: .init(pauseOnThermalPressure: false), lowPower: false))
        policy.thermal.update(.nominal, enabled: true)
        #expect(policy.isPaused(settings: .init(isManuallyPaused: true), lowPower: false))
        policy.sleeping = true
        #expect(policy.isPaused(settings: .init(), lowPower: false))
        policy.sleeping = false
        #expect(!policy.isPaused(settings: .init(), lowPower: false))
    }

    @Test func legacyDefaultsAndExplicitOptOutRoundTrip() throws {
        let legacy = try JSONDecoder().decode(PlaybackSettings.self, from: Data("{}".utf8))
        #expect(legacy.pauseOnThermalPressure)
        let settings = PlaybackSettings(isManuallyPaused: true, pauseOnThermalPressure: false)
        let decoded = try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }
}
