import Foundation

/// Wallpaper playback policy: zero delays use 100 ms; positive file delays stay
/// on the logical timeline. Presentation wakes at most 60 times per second and
/// may skip overdue frames. This is product policy, not claimed browser parity.
public struct GIFTimeline: Sendable {
    private let ends: [Double]
    public let duration: Double
    public static let minimumWakeInterval = 1.0 / 60

    public init(delaysCentiseconds: [UInt16]) {
        var total = 0.0
        ends = delaysCentiseconds.map { value in
            total += value == 0 ? 0.1 : Double(value) / 100
            return total
        }
        duration = total
    }

    public func frame(at elapsed: Double) -> Int {
        guard !ends.isEmpty, duration > 0 else { return 0 }
        let phase = elapsed.isFinite ? max(0, elapsed).truncatingRemainder(dividingBy: duration) : 0
        var low = 0, high = ends.count
        while low < high {
            let middle = (low + high) / 2
            if ends[middle] <= phase { low = middle + 1 } else { high = middle }
        }
        return min(low, ends.count - 1)
    }

    public func nextWake(after elapsed: Double) -> Double {
        guard !ends.isEmpty, duration > 0 else { return 1 }
        let safe = elapsed.isFinite ? max(0, elapsed) : 0
        let phase = safe.truncatingRemainder(dividingBy: duration)
        return max(Self.minimumWakeInterval, ends[frame(at: safe)] - phase)
    }
}
