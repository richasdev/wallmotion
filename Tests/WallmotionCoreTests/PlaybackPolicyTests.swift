import Testing
@testable import WallmotionCore

@Suite("Playback policy")
struct PlaybackPolicyTests {
    @Test func activeSessionStartsPlaying() {
        #expect(!PlaybackPolicy().isPaused(settings: .init(), lowPower: false))
    }

    @Test(arguments: 0..<64)
    func independentPauseReasonsRemainEffective(_ combination: Int) {
        let manualPause = combination & 1 != 0
        let sleeping = combination & 2 != 0
        let inactive = combination & 4 != 0
        let screenAsleep = combination & 8 != 0
        let pauseOnLowPower = combination & 16 != 0
        let lowPower = combination & 32 != 0
        var policy = PlaybackPolicy()
        policy.sleeping = sleeping
        policy.sessionInactive = inactive
        policy.screenAsleep = screenAsleep
        let settings = PlaybackSettings(pauseOnLowPower: pauseOnLowPower, isManuallyPaused: manualPause)

        let reasons = [manualPause, sleeping, inactive, screenAsleep, pauseOnLowPower && lowPower]
        #expect(policy.isPaused(settings: settings, lowPower: lowPower) == reasons.contains(true))
    }

    @Test func resumingSessionPreservesManualPause() {
        var policy = PlaybackPolicy()
        policy.sessionInactive = true
        let settings = PlaybackSettings(isManuallyPaused: true)
        #expect(policy.isPaused(settings: settings, lowPower: false))
        policy.sessionInactive = false
        #expect(policy.isPaused(settings: settings, lowPower: false))
    }

    @Test func wakingSystemDoesNotResumeSleepingScreen() {
        var policy = PlaybackPolicy()
        policy.sleeping = true
        policy.screenAsleep = true
        policy.sleeping = false
        #expect(policy.isPaused(settings: .init(), lowPower: false))
        policy.screenAsleep = false
        #expect(!policy.isPaused(settings: .init(), lowPower: false))
    }

    @Test func resumingSessionPreservesLowPowerPreference() {
        var policy = PlaybackPolicy()
        policy.sessionInactive = true
        policy.sessionInactive = false
        #expect(policy.isPaused(settings: .init(), lowPower: true))
        #expect(!policy.isPaused(settings: .init(pauseOnLowPower: false), lowPower: true))
    }

    @Test func automaticPauseEndsWhenItsReasonClears() {
        var policy = PlaybackPolicy()
        policy.sessionInactive = true
        #expect(policy.isPaused(settings: .init(), lowPower: false))
        policy.sessionInactive = false
        #expect(!policy.isPaused(settings: .init(), lowPower: false))
    }
}
