import Testing
@testable import WallmotionCore

@Suite("GIF wallpaper timing")
struct GIFTimelineTests {
    @Test func exactBoundariesLoopAndSkipOverdueFrames() {
        let timeline = GIFTimeline(delaysCentiseconds: [10, 20, 30])
        #expect(abs(timeline.duration - 0.6) < 0.000_001)
        #expect(timeline.frame(at: 0.099) == 0)
        #expect(timeline.frame(at: 0.1) == 1)
        #expect(timeline.frame(at: 0.301) == 2)
        #expect(timeline.frame(at: timeline.duration) == 0)
        #expect(timeline.frame(at: timeline.duration * 5 + 0.4) == 2)
        #expect(abs(timeline.nextWake(after: 0.4) - 0.2) < 0.000_001)
    }
    @Test func zeroDelayPolicyAndPositiveRawDelaysKeepLogicalTime() {
        let timeline = GIFTimeline(delaysCentiseconds: [0, 1, 1, 50])
        #expect(abs(timeline.duration - 0.62) < 0.000_001)
        #expect(timeline.frame(at: 0.099) == 0)
        #expect(timeline.frame(at: 0.105) == 1)
        #expect(timeline.frame(at: 0.115) == 2)
        #expect(timeline.frame(at: 0.13) == 3)
        #expect(timeline.nextWake(after: 0.105) == GIFTimeline.minimumWakeInterval)
    }
    @Test func emptyNonfiniteAndNegativeTimesRemainBounded() {
        let empty = GIFTimeline(delaysCentiseconds: [])
        #expect(empty.frame(at: 100) == 0)
        #expect(empty.nextWake(after: 100) == 1)
        let timeline = GIFTimeline(delaysCentiseconds: [10, 20])
        for invalid in [Double.nan, .infinity, -.infinity, -1] {
            #expect(timeline.frame(at: invalid) == 0)
            #expect(timeline.nextWake(after: invalid) == 0.1)
        }
    }
}
