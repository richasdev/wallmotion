/// Event-driven pressure hysteresis. Initial state means no critical event has
/// been observed; it is not a synchronous measurement of available memory.
public struct MemoryPressurePolicy: Sendable, Equatable {
    public enum Pressure: Sendable, Equatable { case normal, warning, critical }
    public private(set) var isPaused = false

    public init() {}

    public mutating func update(_ pressure: Pressure, enabled: Bool) {
        guard enabled else { isPaused = false; return }
        switch pressure {
        case .critical: isPaused = true
        case .normal: isPaused = false
        case .warning: break
        }
    }
}
