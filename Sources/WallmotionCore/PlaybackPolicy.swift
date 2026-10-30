public struct PlaybackPolicy: Sendable, Equatable {
    public var sleeping = false
    public var sessionInactive = false
    public var screenAsleep = false

    public init() {}

    public func isPaused(settings: PlaybackSettings, lowPower: Bool) -> Bool {
        settings.isManuallyPaused
            || sleeping
            || sessionInactive
            || screenAsleep
            || (settings.pauseOnLowPower && lowPower)
    }
}
