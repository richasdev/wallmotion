import AppKit
import WallmotionCore

@MainActor
protocol VisibleApplicationMonitoring: AnyObject {
    func start(displayIDs: Set<String>, onChange: @escaping @MainActor (Set<String>) -> Void)
    func update(displayIDs: Set<String>)
    func refresh()
    func stop()
}

enum VisibleApplicationWindowReader {
    @MainActor static func regularApplicationPIDs() -> Set<Int32> {
        // Window alpha does not describe transparent pixels in an overlay.
        // Exclude accessory/prohibited/unknown owners instead of inspecting
        // content, titles or names. Menu-bar-only apps intentionally do not pause.
        Set(NSWorkspace.shared.runningApplications.compactMap { application in
            guard !application.isTerminated, application.activationPolicy == .regular else { return nil }
            return application.processIdentifier
        })
    }

    static func read() -> [VisibleApplicationWindow]? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return info.compactMap(parse)
    }

    static func parse(_ info: [String: Any]) -> VisibleApplicationWindow? {
        guard let pid = info[kCGWindowOwnerPID as String] as? NSNumber,
              let layer = info[kCGWindowLayer as String] as? NSNumber,
              let alpha = info[kCGWindowAlpha as String] as? NSNumber,
              let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary) else { return nil }
        return VisibleApplicationWindow(ownerPID: pid.int32Value, layer: layer.intValue, alpha: alpha.doubleValue,
            bounds: bounds, isOnscreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true)
    }

    @MainActor static func displayBounds() -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        for screen in NSScreen.screens {
            guard let id = Display.identify(screen),
                  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            // Both APIs use the same upper-left global display coordinates.
            // Do not flip NSScreen.frame or multiply by backingScaleFactor.
            result[id] = CGDisplayBounds(number.uint32Value)
        }
        return result
    }
}

/// One background metadata query at a time, no capture/AX permission requests.
/// A two-second timer covers moves/minimization; workspace bursts are coalesced.
@MainActor
final class VisibleApplicationMonitor: VisibleApplicationMonitoring {
    private let worker: VisibleWindowQueryWorker
    private let displayBounds: @MainActor () -> [String: CGRect]
    private let regularApplicationPIDs: @MainActor () -> Set<Int32>
    private let center: NotificationCenter
    private let ownPID: Int32
    private var displayIDs = Set<String>()
    private var onChange: (@MainActor (Set<String>) -> Void)?
    private var lastResult: Set<String>?
    private let events: VisibleMonitorEvents
    private var query: Task<Void, Never>?
    private var invalidation: Task<Void, Never>?
    private var generation = UUID()
    var isRunning: Bool { events.timer != nil }

    init(readWindows: @escaping @Sendable () -> [VisibleApplicationWindow]? = VisibleApplicationWindowReader.read,
         regularApplicationPIDs: @escaping @MainActor () -> Set<Int32> = VisibleApplicationWindowReader.regularApplicationPIDs,
         displayBounds: @escaping @MainActor () -> [String: CGRect] = VisibleApplicationWindowReader.displayBounds,
         center: NotificationCenter = NSWorkspace.shared.notificationCenter, ownPID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        worker = VisibleWindowQueryWorker(readWindows: readWindows)
        self.regularApplicationPIDs = regularApplicationPIDs
        self.displayBounds = displayBounds; self.center = center; self.ownPID = ownPID
        events = VisibleMonitorEvents(center: center)
    }

    func start(displayIDs: Set<String>, onChange: @escaping @MainActor (Set<String>) -> Void) {
        guard !displayIDs.isEmpty else { stop(); return }
        if isRunning { self.onChange = onChange; update(displayIDs: displayIDs); return }
        self.displayIDs = displayIDs; self.onChange = onChange; lastResult = nil
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        events.timer = timer
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            events.observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        poll()
    }

    func update(displayIDs: Set<String>) {
        guard !displayIDs.isEmpty else { stop(); return }
        guard self.displayIDs != displayIDs else { return }
        self.displayIDs = displayIDs
        generation = UUID(); query?.cancel(); query = nil
        poll()
    }

    func refresh() {
        guard isRunning, invalidation == nil else { return }
        invalidation = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            self?.invalidation = nil
            self?.poll()
        }
    }

    func poll() {
        guard isRunning, query == nil else { return }
        let bounds = displayBounds().filter { displayIDs.contains($0.key) }
        let regularApplicationPIDs = regularApplicationPIDs()
        let generation = generation, worker = worker, ownPID = ownPID
        query = Task(priority: .utility) { @MainActor [weak self] in
            let result = await worker.occupiedDisplays(bounds: bounds, ownPID: ownPID, regularApplicationPIDs: regularApplicationPIDs)
            guard let self, !Task.isCancelled, self.generation == generation, self.isRunning else { return }
            self.query = nil
            guard self.lastResult != result else { return }
            self.lastResult = result
            self.onChange?(result)
        }
    }

    func stop() {
        generation = UUID()
        events.cancel()
        query?.cancel(); query = nil
        invalidation?.cancel(); invalidation = nil
        displayIDs = []; onChange = nil; lastResult = nil
    }

    deinit {
        query?.cancel(); invalidation?.cancel()
    }
}

/// Serializes the synchronous WindowServer query even during rapid stop/start.
/// Cancelled queued requests exit before touching WindowServer.
private actor VisibleWindowQueryWorker {
    let readWindows: @Sendable () -> [VisibleApplicationWindow]?
    init(readWindows: @escaping @Sendable () -> [VisibleApplicationWindow]?) { self.readWindows = readWindows }
    func occupiedDisplays(bounds: [String: CGRect], ownPID: Int32, regularApplicationPIDs: Set<Int32>) -> Set<String> {
        guard !Task.isCancelled, !regularApplicationPIDs.isEmpty else { return [] }
        return VisibleApplicationWindow.occupiedDisplays(windows: readWindows(), displayBounds: bounds, ownPID: ownPID,
            regularApplicationPIDs: regularApplicationPIDs)
    }
}

/// Owned exclusively by the main-actor monitor. Its final release may occur on
/// another executor, so destruction transfers immutable cleanup to the main loop
/// where the timer was installed. No callbacks retain the monitor.
private final class VisibleMonitorEvents: @unchecked Sendable {
    var timer: Timer?
    var observers: [NSObjectProtocol] = []
    private let center: NotificationCenter
    init(center: NotificationCenter) { self.center = center }
    @MainActor func cancel() {
        timer?.invalidate(); timer = nil
        observers.forEach(center.removeObserver); observers.removeAll()
    }
    deinit {
        let cleanup = VisibleMonitorEventCleanup(timer: timer, center: center, observers: observers)
        DispatchQueue.main.async { cleanup.cancel() }
    }
}

private final class VisibleMonitorEventCleanup: @unchecked Sendable {
    let timer: Timer?
    let center: NotificationCenter
    let observers: [NSObjectProtocol]
    init(timer: Timer?, center: NotificationCenter, observers: [NSObjectProtocol]) {
        self.timer = timer; self.center = center; self.observers = observers
    }
    @MainActor func cancel() {
        timer?.invalidate()
        observers.forEach(center.removeObserver)
    }
}
