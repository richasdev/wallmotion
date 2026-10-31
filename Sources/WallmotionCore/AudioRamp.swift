import Foundation

/// A bounded gain envelope; timing and cancellation belong to its transport.
/// Smoothstep has zero slope at both endpoints and never overshoots [0, 1].
public struct AudioRamp: Sendable {
    public let start: Double
    public let target: Double
    public let duration: Double

    public init(start: Double, target: Double, duration: Double = 0.2) {
        self.start = Self.level(start)
        self.target = Self.level(target)
        self.duration = duration.isFinite ? max(0, duration) : 0
    }

    public func value(at elapsed: Double) -> Double {
        guard !elapsed.isNaN else { return 0 }
        guard duration > 0 else { return target }
        let phase = min(1, max(0, elapsed / duration))
        let eased = phase * phase * (3 - 2 * phase)
        return Self.level(start + (target - start) * eased)
    }

    public func isComplete(at elapsed: Double) -> Bool {
        duration == 0 || elapsed >= duration
    }

    private static func level(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }
}
