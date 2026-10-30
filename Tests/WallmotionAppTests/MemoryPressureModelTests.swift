import AppKit
import Dispatch
import XCTest
import WallmotionCore
@testable import Wallmotion

@MainActor
final class MemoryPressureModelTests: XCTestCase {
    private final class Values { var windows: [NSWindow] = []; var purges = 0 }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Memory-policy fixture did not settle") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testCriticalReleasesOwnedGIFAndNormalRecoveryPreservesManualPauseAndState() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Graphical fixture requires a screen") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionMemory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("tiny.gif")
        try Data([0x47,0x49,0x46,0x38,0x39,0x61,1,0,1,0,0x80,0,0,0,0,0,0xff,0xff,0xff,0x2c,0,0,0,0,1,0,1,0,0,2,2,0x44,1,0,0x3b]).write(to: file)
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        let item = try store.importFile(at: file)
        let state = LibraryState(wallpapers: [item], assignments: ["fixture": item.id], settings: .init(pauseOnLowPower: false))
        try store.save(state)
        let saved = try Data(contentsOf: store.stateURL)
        let values = Values()
        let monitor = TestMemoryPressureMonitor()
        let engine = DesktopCoordinator(targets: { [DesktopTarget(id: "fixture", screen: screen, frame: CGRect(x: -20000, y: -20000, width: 32, height: 32), backingScale: 1)] }, isWindowVisible: { window in
            if !values.windows.contains(where: { $0 === window }) { values.windows.append(window) }
            return true
        })
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: monitor, purgeThumbnails: { values.purges += 1 }, store: store, engine: engine, connectedDisplays: { [Display(id: "fixture", name: "Synthetic")] })
        defer { model.stop() }
        model.start()
        model.start()
        XCTAssertEqual(monitor.starts, 1)
        try await waitUntil { engine.gifBudget.totalBytes > 0 }
        let original = try XCTUnwrap(values.windows.first)
        monitor.send(.warning)
        XCTAssertTrue(original.isVisible)
        XCTAssertFalse(model.isPaused)
        XCTAssertTrue(model.playbackDescription.contains("aguardam memória"))
        monitor.send(.critical)
        XCTAssertTrue(model.resourcesReleasedForMemory)
        XCTAssertTrue(model.isPaused)
        XCTAssertFalse(original.isVisible)
        XCTAssertNil(original.contentView)
        XCTAssertEqual(engine.gifBudget.totalBytes, 0)
        XCTAssertEqual(model.state, state)
        XCTAssertEqual(try Data(contentsOf: store.stateURL), saved)
        XCTAssertEqual(values.purges, 2)
        model.refreshPlayback(force: false)
        XCTAssertEqual(values.windows.count, 1, "Unrelated refresh must not recreate renderers while latched.")
        monitor.send(.warning)
        XCTAssertTrue(model.resourcesReleasedForMemory)
        model.togglePause()
        XCTAssertEqual(model.manualPauseActionTitle, "Liberar pausa manual")
        monitor.send(.normal)
        try await waitUntil { values.windows.count == 2 }
        XCTAssertFalse(model.resourcesReleasedForMemory)
        XCTAssertTrue(model.isPaused)
        let surface = try XCTUnwrap(values.windows.last?.contentView as? ImageSurface)
        XCTAssertFalse(surface.imageView.animates)
        XCTAssertEqual(model.state.assignments, state.assignments)
        model.togglePause()
        XCTAssertFalse(model.isPaused)
        XCTAssertTrue(surface.imageView.animates)
        model.stop()
        XCTAssertEqual(monitor.stops, 1)
        monitor.send(.critical)
        XCTAssertFalse(model.resourcesReleasedForMemory)
    }

    func testOptOutPersistenceFailureAndStoppedEventsDoNotChangePolicy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionMemoryPreferences-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = TestMemoryPressureMonitor()
        let store = LibraryStore(rootURL: root)
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: monitor, purgeThumbnails: {}, store: store, engine: DesktopCoordinator(targets: { [] }), connectedDisplays: { [] })
        defer { model.stop() }
        model.setPauseOnLowPower(false)
        model.setPauseOnMemoryPressure(false)
        XCTAssertFalse(try store.load().settings.pauseOnMemoryPressure)
        model.start()
        monitor.send(.critical)
        XCTAssertFalse(model.isPaused)
        XCTAssertFalse(model.resourcesReleasedForMemory)
        var reloaded = model.state
        reloaded.settings.pauseOnMemoryPressure = true
        try store.save(reloaded)
        model.load() // Reload must honor the already-observed critical event too.
        XCTAssertTrue(model.resourcesReleasedForMemory)
        XCTAssertTrue(model.isPaused)
        try FileManager.default.removeItem(at: store.stateURL)
        try FileManager.default.createDirectory(at: store.stateURL, withIntermediateDirectories: false)
        model.setPauseOnMemoryPressure(false)
        XCTAssertTrue(model.state.settings.pauseOnMemoryPressure)
        XCTAssertTrue(model.resourcesReleasedForMemory)
        XCTAssertNotNil(model.errorMessage)
    }

    func testDispatchEventMappingPrioritizesCriticalAndMonitorCanStopRestart() {
        XCTAssertNil(SystemMemoryPressureMonitor.pressure(from: []))
        XCTAssertEqual(SystemMemoryPressureMonitor.pressure(from: [.normal, .warning]), .warning)
        XCTAssertEqual(SystemMemoryPressureMonitor.pressure(from: [.normal, .warning, .critical]), .critical)
        XCTAssertEqual(SystemMemoryPressureMonitor.pressure(from: [.normal]), .normal)
        let monitor = SystemMemoryPressureMonitor()
        monitor.start { _ in }
        monitor.stop()
        monitor.start { _ in }
        monitor.stop()
    }
}
