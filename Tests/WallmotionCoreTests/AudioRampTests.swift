import Testing
@testable import WallmotionCore

@Suite("Manual audio ramp envelope")
struct AudioRampTests {
    @Test func endpointsMidpointAndMonotonicityHaveNoOvershoot() {
        for (start, target) in [(0.0, 1.0), (1.0, 0.0), (0.3, 0.7), (0.7, 0.3)] {
            let ramp = AudioRamp(start: start, target: target)
            #expect(ramp.value(at: -1) == start)
            #expect(ramp.value(at: 0) == start)
            #expect(abs(ramp.value(at: 0.1) - (start + target) / 2) < 0.000_001)
            #expect(abs(ramp.value(at: 0.2) - target) < 0.000_001)
            #expect(abs(ramp.value(at: 100) - target) < 0.000_001)
            var previous = start
            for step in 1...100 {
                let value = ramp.value(at: Double(step) * 0.002)
                #expect((0...1).contains(value))
                #expect(target >= start ? value >= previous : value <= previous)
                previous = value
            }
            #expect(!ramp.isComplete(at: 0.199))
            #expect(ramp.isComplete(at: 0.2))
        }
    }
    @Test func reversalStartsAtTheActualCurrentEnvelope() {
        let initial = AudioRamp(start: 1, target: 0)
        let current = initial.value(at: 0.075)
        let reverse = AudioRamp(start: current, target: 1)
        #expect(reverse.value(at: 0) == current)
        #expect(reverse.value(at: 0.1) > current)
        #expect(reverse.value(at: 0.2) == 1)
    }
    @Test func malformedInputsCannotProduceNonfiniteOrOutOfRangeGain() {
        for invalid in [Double.nan, .infinity, -.infinity, -1] {
            let ramp = AudioRamp(start: invalid, target: invalid, duration: invalid)
            #expect(ramp.value(at: 0).isFinite)
            #expect((0...1).contains(ramp.value(at: 0)))
        }
        let ramp = AudioRamp(start: 1, target: 0)
        #expect(ramp.value(at: .nan) == 0)
        #expect(ramp.value(at: .infinity) == 0)
        #expect(ramp.value(at: -.infinity) == 1)
        #expect(AudioRamp(start: 0, target: 0.5, duration: 0).value(at: 0) == 0.5)
    }
}
