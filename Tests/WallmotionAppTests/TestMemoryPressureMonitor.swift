import WallmotionCore
@testable import Wallmotion

@MainActor
final class TestMemoryPressureMonitor: MemoryPressureMonitoring {
    private var handler: (@MainActor @Sendable (MemoryPressurePolicy.Pressure) -> Void)?
    private(set) var starts = 0
    private(set) var stops = 0

    func start(_ handler: @escaping @MainActor @Sendable (MemoryPressurePolicy.Pressure) -> Void) {
        starts += 1
        self.handler = handler
    }
    func stop() { stops += 1; handler = nil }
    func send(_ pressure: MemoryPressurePolicy.Pressure) { handler?(pressure) }
}
