/// Hysteresis for the OS pressure signal; this is not a temperature measurement.
public struct ThermalPausePolicy: Sendable, Equatable {
    public enum Pressure: Sendable { case nominal, fair, serious, critical }
    public private(set) var isPaused = false

    public init() {}

    public mutating func update(_ pressure: Pressure, enabled: Bool) {
        guard enabled else { isPaused = false; return }
        switch pressure {
        case .serious, .critical: isPaused = true
        case .nominal: isPaused = false
        case .fair: break // Keep the previous state until the OS reports nominal.
        }
    }
}
