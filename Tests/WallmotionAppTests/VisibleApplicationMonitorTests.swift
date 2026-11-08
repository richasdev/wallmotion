import AppKit
import XCTest
import WallmotionCore
@testable import Wallmotion

private final class VisibleWindowSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [VisibleApplicationWindow]?
    private var reads = 0
    init(_ value: [VisibleApplicationWindow]?) { self.value = value }
    func set(_ value: [VisibleApplicationWindow]?) { lock.withLock { self.value = value } }
    func read() -> [VisibleApplicationWindow]? { lock.withLock { reads += 1; return value } }
    var count: Int { lock.withLock { reads } }
}

private final class SerialWindowSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    let releaseFirst = DispatchSemaphore(value: 0)
    private var reads = 0
    private var active = 0
    private var maximum = 0
    var count: Int { lock.withLock { reads } }
    var maximumConcurrentReads: Int { lock.withLock { maximum } }
    func read() -> [VisibleApplicationWindow]? {
        let index = lock.withLock { reads += 1; active += 1; maximum = max(maximum, active); return reads }
        defer { lock.withLock { active -= 1 } }
        if index == 1 { _ = releaseFirst.wait(timeout: .now() + 5) }
        return [VisibleApplicationWindow(ownerPID: 12, layer: 0, alpha: 1,
            bounds: CGRect(x: index == 1 ? -900 : 100, y: 20, width: 200, height: 100))]
    }
}

@MainActor final class VisibleApplicationMonitorTests: XCTestCase {
    @MainActor private final class RegularOwners {
        var pids: Set<Int32> = [12]
        var reads = 0
        func snapshot() -> Set<Int32> { reads += 1; return pids }
    }
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    func testParserNeedsOnlyPublicGeometryPIDAndFlagsAndNeverOwnerNameOrTitle() throws {
        let bounds = CGRect(x: -900, y: 20, width: 200, height: 100)
        var info: [String: Any] = [kCGWindowOwnerPID as String: NSNumber(value: 12), kCGWindowLayer as String: 0,
            kCGWindowAlpha as String: 1.0, kCGWindowBounds as String: bounds.dictionaryRepresentation]
        let parsed = try XCTUnwrap(VisibleApplicationWindowReader.parse(info))
        XCTAssertEqual(parsed.ownerPID, 12); XCTAssertEqual(parsed.bounds, bounds); XCTAssertTrue(parsed.isOnscreen)
        info[kCGWindowIsOnscreen as String] = false
        XCTAssertFalse(try XCTUnwrap(VisibleApplicationWindowReader.parse(info)).isOnscreen)
        info[kCGWindowBounds as String] = nil
        XCTAssertNil(VisibleApplicationWindowReader.parse(info))
    }
    func testGatedSourceUpdatesOccupancyForMovesMinimizeFailureHotplugAndStopsWithoutLateCallbacks() async throws {
        let snapshot = VisibleWindowSnapshot([VisibleApplicationWindow(ownerPID: 12, layer: 0, alpha: 1, bounds: CGRect(x: -900, y: 20, width: 200, height: 100))])
        let center = NotificationCenter()
        let monitor = VisibleApplicationMonitor(readWindows: { snapshot.read() },
            regularApplicationPIDs: { [12] },
            displayBounds: { ["left": CGRect(x: -1000, y: 0, width: 1000, height: 800), "right": CGRect(x: 0, y: 0, width: 1000, height: 800)] }, center: center, ownPID: 1)
        var results: [Set<String>] = []
        monitor.refresh(); monitor.poll()
        XCTAssertEqual(snapshot.count, 0); XCTAssertFalse(monitor.isRunning)
        monitor.start(displayIDs: ["left", "right"]) { results.append($0) }
        try await waitUntil { results.last == ["left"] }
        snapshot.set([VisibleApplicationWindow(ownerPID: 12, layer: 0, alpha: 1, bounds: CGRect(x: 20, y: 20, width: 200, height: 100))])
        monitor.poll()
        try await waitUntil { results.last == ["right"] }
        snapshot.set([]); center.post(name: NSWorkspace.didHideApplicationNotification, object: nil)
        try await waitUntil { results.last == [] }
        snapshot.set(nil); monitor.poll()
        try await waitUntil { snapshot.count >= 4 }
        XCTAssertEqual(results.last, [])
        snapshot.set([VisibleApplicationWindow(ownerPID: 12, layer: 0, alpha: 1, bounds: CGRect(x: 20, y: 20, width: 200, height: 100))])
        monitor.update(displayIDs: ["left"])
        try await waitUntil { snapshot.count >= 5 }
        XCTAssertEqual(results.last, [])
        monitor.stop()
        let count = snapshot.count, callbacks = results.count
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        monitor.refresh(); monitor.poll()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(monitor.isRunning); XCTAssertEqual(snapshot.count, count); XCTAssertEqual(results.count, callbacks)
    }
    func testEmptyAssignmentsNeverStartTimerAndDeallocationHasNoRetainCycle() {
        let snapshot = VisibleWindowSnapshot([])
        var monitor: VisibleApplicationMonitor? = VisibleApplicationMonitor(readWindows: { snapshot.read() }, regularApplicationPIDs: { [12] }, displayBounds: { [:] }, center: NotificationCenter())
        monitor?.start(displayIDs: []) { _ in XCTFail("No assigned display") }
        XCTAssertFalse(monitor?.isRunning ?? true); XCTAssertEqual(snapshot.count, 0)
        monitor?.start(displayIDs: ["one"]) { _ in }
        weak var weakMonitor = monitor
        monitor = nil
        XCTAssertNil(weakMonitor)
        weakMonitor = nil
    }

    func testRegularOwnerSnapshotRejectsHelperOverlaysAndChangesPerQueryWithoutReadingWindowsWhenEmpty() async throws {
        let overlay = CGRect(x: -1000, y: 0, width: 2560, height: 1080)
        // Accessory, prohibited and unknown owners are absent from the injected
        // regular-app snapshot, regardless of layer zero or alpha one.
        let helpers = [13, 14, 15].map { VisibleApplicationWindow(ownerPID: Int32($0), layer: 0, alpha: 1, bounds: overlay) }
        let snapshot = VisibleWindowSnapshot(helpers), owners = RegularOwners()
        let monitor = VisibleApplicationMonitor(readWindows: { snapshot.read() }, regularApplicationPIDs: { owners.snapshot() },
            displayBounds: { ["left": CGRect(x: -1000, y: 0, width: 1000, height: 800)] }, center: NotificationCenter(), ownPID: 1)
        defer { monitor.stop() }
        var results: [Set<String>] = []
        monitor.start(displayIDs: ["left"]) { results.append($0) }
        try await waitUntil { results.count == 1 }
        XCTAssertEqual(results.last, [])
        snapshot.set([VisibleApplicationWindow(ownerPID: 12, layer: 0, alpha: 1, bounds: overlay)])
        monitor.poll()
        try await waitUntil { results.last == ["left"] }
        XCTAssertEqual(snapshot.count, 2)
        // The same window metadata cannot keep the display paused after its
        // owner is terminated, unknown or changes to a non-regular policy.
        owners.pids = []
        monitor.poll()
        try await waitUntil { results.count == 3 }
        XCTAssertEqual(results.last, [])
        XCTAssertEqual(snapshot.count, 2, "An empty owner snapshot must avoid WindowServer entirely")
        owners.pids = [12]
        monitor.poll()
        try await waitUntil { results.count == 4 }
        XCTAssertEqual(results.last, ["left"])
        XCTAssertEqual(owners.reads, 4, "Take exactly one owner snapshot per query")
        XCTAssertEqual(snapshot.count, 3)
    }

    func testRestartSerializesSlowQueryAndRejectsItsOldGenerationAndCoalescesWorkspaceBursts() async throws {
        let snapshot = SerialWindowSnapshot(), center = NotificationCenter()
        let monitor = VisibleApplicationMonitor(readWindows: { snapshot.read() }, regularApplicationPIDs: { [12] }, displayBounds: {
            ["left": CGRect(x: -1000, y: 0, width: 1000, height: 800), "right": CGRect(x: 0, y: 0, width: 1000, height: 800)]
        }, center: center, ownPID: 1)
        defer { snapshot.releaseFirst.signal(); monitor.stop() }
        var results: [Set<String>] = []
        monitor.start(displayIDs: ["left", "right"]) { _ in XCTFail("Stale generation published") }
        try await waitUntil { snapshot.count == 1 }
        monitor.stop()
        monitor.start(displayIDs: ["left", "right"]) { results.append($0) }
        snapshot.releaseFirst.signal()
        try await waitUntil { results.last == ["right"] }
        XCTAssertEqual(snapshot.maximumConcurrentReads, 1)
        let before = snapshot.count
        for _ in 0..<30 { center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil) }
        try await waitUntil { snapshot.count == before + 1 }
        XCTAssertEqual(snapshot.maximumConcurrentReads, 1)
        XCTAssertEqual(results, [["right"]], "Unchanged metadata must not repeat renderer work")
    }
}
