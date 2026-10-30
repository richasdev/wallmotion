import Foundation
import Testing
@testable import WallmotionCore

@Suite("Memory pressure policy")
struct MemoryPressurePolicyTests {
    @Test func criticalLatchesThroughWarningUntilNormalAndOptOutClearsIt() {
        var policy = MemoryPressurePolicy()
        policy.update(.warning, enabled: true)
        #expect(!policy.isPaused)
        policy.update(.critical, enabled: true)
        #expect(policy.isPaused)
        policy.update(.warning, enabled: true)
        #expect(policy.isPaused)
        policy.update(.normal, enabled: true)
        #expect(!policy.isPaused)
        policy.update(.critical, enabled: true)
        policy.update(.critical, enabled: false)
        #expect(!policy.isPaused)
    }

    @Test func memoryRecoveryDoesNotOverrideManualThermalOrLowPowerReasons() {
        var policy = PlaybackPolicy()
        var settings = PlaybackSettings()
        policy.memory.update(.critical, enabled: true)
        #expect(policy.isPaused(settings: settings, lowPower: false))
        settings.isManuallyPaused = true
        policy.memory.update(.normal, enabled: true)
        #expect(policy.isPaused(settings: settings, lowPower: false))
        settings.isManuallyPaused = false
        policy.thermal.update(.serious, enabled: true)
        #expect(policy.isPaused(settings: settings, lowPower: false))
        policy.thermal.update(.nominal, enabled: true)
        #expect(policy.isPaused(settings: settings, lowPower: true))
        #expect(!policy.isPaused(settings: settings, lowPower: false))
    }

    @Test func legacyPreferenceDefaultsOnAndOptOutRoundTrips() throws {
        let legacy = try JSONDecoder().decode(PlaybackSettings.self, from: Data("{}".utf8))
        #expect(legacy.pauseOnMemoryPressure)
        let settings = PlaybackSettings(pauseOnMemoryPressure: false)
        #expect(try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }
}
