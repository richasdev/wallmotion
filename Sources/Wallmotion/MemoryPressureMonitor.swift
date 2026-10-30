import Dispatch
import WallmotionCore

@MainActor
protocol MemoryPressureMonitoring: AnyObject {
    func start(_ handler: @escaping @MainActor @Sendable (MemoryPressurePolicy.Pressure) -> Void)
    func stop()
}

@MainActor
final class SystemMemoryPressureMonitor: MemoryPressureMonitoring {
    private var source: (any DispatchSourceMemoryPressure)?
    private var generation = 0

    static func pressure(from events: DispatchSource.MemoryPressureEvent) -> MemoryPressurePolicy.Pressure? {
        if events.contains(.critical) { return .critical }
        if events.contains(.warning) { return .warning }
        if events.contains(.normal) { return .normal }
        return nil
    }

    func start(_ handler: @escaping @MainActor @Sendable (MemoryPressurePolicy.Pressure) -> Void) {
        stop()
        let ticket = generation
        let watcher = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source = watcher
        watcher.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == ticket, let current = self.source,
                      let pressure = Self.pressure(from: current.data) else { return }
                handler(pressure)
            }
        }
        watcher.activate()
    }

    func stop() {
        generation += 1
        source?.setEventHandler {}
        source?.cancel()
        source = nil
    }

    deinit { source?.cancel() }
}
