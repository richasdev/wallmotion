import AppKit
import AVFoundation
import XCTest
import WallmotionCore
@testable import Wallmotion

@MainActor private final class TestVisibleApplicationMonitor: VisibleApplicationMonitoring {
    var callback: (@MainActor (Set<String>) -> Void)?
    var ids = Set<String>()
    var starts = 0
    var stops = 0
    func start(displayIDs: Set<String>, onChange: @escaping @MainActor (Set<String>) -> Void) { starts += 1; ids = displayIDs; callback = onChange }
    func update(displayIDs: Set<String>) { ids = displayIDs }
    func refresh() {}
    func stop() { stops += 1; ids = []; callback = nil }
    func emit(_ ids: Set<String>) { callback?(ids) }
}

@MainActor final class VisibleApplicationPauseTests: XCTestCase {
    @MainActor private final class Environment {
        var targets: [DesktopTarget]
        var windows: [NSWindow] = []
        init(screen: NSScreen) {
            targets = [DesktopTarget(id: "left", screen: screen, frame: CGRect(x: -10000, y: -10000, width: 160, height: 90)),
                       DesktopTarget(id: "right", screen: screen, frame: CGRect(x: -9800, y: -10000, width: 160, height: 90))]
        }
        func visible(_ window: NSWindow) -> Bool {
            if !windows.contains(where: { $0 === window }) { windows.append(window) }
            return true
        }
        func window(_ id: String) -> NSWindow? { windows.last { $0.contentView != nil && $0.frame.minX == (id == "left" ? -10000 : -9800) } }
        func player(_ id: String) -> AVPlayer? { (window(id)?.contentView as? VideoSurface)?.playerLayer.player }
    }
    private func fixture() async throws -> (URL, LibraryStore, Wallpaper) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionVisibleAppPause-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent("generated.mp4")
        try await LocalVideoFixture.write(at: url, frames: 90, fps: 3)
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        return (root, store, try store.importFile(at: url))
    }
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    private func verifyRuntime(mode: DisplayMode) async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let (root, store, item) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let environment = Environment(screen: screen)
        let engine = DesktopCoordinator(targets: { environment.targets }, isWindowVisible: { environment.visible($0) }, sharedVideoLayerReady: { _ in true })
        defer { engine.stop() }
        let state = LibraryState(wallpapers: [item], assignments: ["left": item.id, "right": item.id],
            settings: .init(pauseOnLowPower: false, audioDisplayID: "left", audioVolume: 0.7), displayMode: mode, mirroredWallpaperID: item.id)
        engine.scheduleRebuild(state: state, store: store, paused: false) { _, error in XCTFail(error) }
        try await waitUntil { environment.player("left")?.timeControlStatus == .playing && environment.player("right")?.timeControlStatus == .playing }
        let left = try XCTUnwrap(environment.player("left")), right = try XCTUnwrap(environment.player("right"))
        let leftItem = try XCTUnwrap(left.currentItem), rightItem = try XCTUnwrap(right.currentItem)
        let count = environment.windows.count
        engine.setVisibleAppPausedDisplays(["left"])
        XCTAssertTrue(left.isMuted, "A covered audio owner must not leak sound or transfer ownership")
        if mode.isShared {
            XCTAssertTrue(left === right)
            XCTAssertFalse(try XCTUnwrap(environment.window("left")).isVisible, "Covered shared output reveals the system background")
            XCTAssertTrue((environment.window("left")?.contentView as? VideoSurface)?.playerLayer.isHidden == true)
        } else { XCTAssertEqual(left.rate, 0) }
        XCTAssertEqual(right.rate, 1)
        let before = right.currentTime().seconds
        try await waitUntil { right.currentTime().seconds > before + 0.05 }
        engine.setVisibleAppPausedDisplays(["left", "right"])
        XCTAssertEqual(left.rate, 0); XCTAssertEqual(right.rate, 0)
        engine.setPaused(true)
        engine.setVisibleAppPausedDisplays([])
        XCTAssertEqual(left.rate, 0); XCTAssertEqual(right.rate, 0, "An occupancy change cannot undo global pause")
        engine.setPaused(false)
        try await waitUntil { left.timeControlStatus == .playing && right.timeControlStatus == .playing }
        XCTAssertFalse(left.isMuted); XCTAssertEqual(left.volume, 0.7, accuracy: 0.0001)
        if !mode.isShared { XCTAssertTrue(right.isMuted) }
        XCTAssertTrue(left.currentItem === leftItem); XCTAssertTrue(right.currentItem === rightItem)
        XCTAssertEqual(environment.windows.count, count)
        // A retained covered reason applies to new/reused surfaces during rebuild.
        engine.setVisibleAppPausedDisplays(["left"])
        engine.scheduleRebuild(state: state, store: store, paused: false) { _, error in XCTFail(error) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(left.isMuted); XCTAssertEqual(right.rate, 1)
        let disconnected = environment.targets.removeFirst()
        engine.scheduleRebuild(state: state, store: store, paused: false) { _, error in XCTFail(error) }
        try await waitUntil { environment.window("left") == nil }
        XCTAssertEqual(right.rate, 1)
        environment.targets.insert(disconnected, at: 0)
        engine.scheduleRebuild(state: state, store: store, paused: false) { _, error in XCTFail(error) }
        try await waitUntil { environment.window("left") != nil }
        XCTAssertTrue(environment.player("left")?.isMuted == true)
        engine.stop()
        XCTAssertNil(right.currentItem)
    }
    func testIndependentVideoPausesOnlyOccupiedMonitorAndPreservesOtherPlayerItemAndAudioPolicy() async throws { try await verifyRuntime(mode: .independent) }
    func testMirrorVotesKeepFreeDisplayAdvancingWithoutGhostOwnerAudio() async throws { try await verifyRuntime(mode: .mirrored) }
    func testPanoramaVotesKeepFreeDisplayAdvancingWithoutGhostOwnerAudio() async throws { try await verifyRuntime(mode: .spanned) }

    func testModelPreferenceStatusGatingManualSleepHotplugAndStopPreserveOtherPauseReasons() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let (root, store, item) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let environment = Environment(screen: screen), monitor = TestVisibleApplicationMonitor()
        try store.save(LibraryState(wallpapers: [item], assignments: ["left": item.id, "right": item.id], settings: .init(pauseOnLowPower: false)))
        let engine = DesktopCoordinator(targets: { environment.targets }, isWindowVisible: { environment.visible($0) })
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), visibleApplicationMonitor: monitor,
            purgeThumbnails: {}, store: store, engine: engine, connectedDisplays: { environment.targets.map { Display(id: $0.id, name: $0.id) } })
        defer { model.stop() }
        model.start()
        try await waitUntil { environment.player("left")?.timeControlStatus == .playing && environment.player("right")?.timeControlStatus == .playing }
        XCTAssertEqual(monitor.starts, 0, "Disabled by default; no event source or timer")
        model.setPauseWhenOtherAppsVisible(true)
        XCTAssertEqual(monitor.starts, 1); XCTAssertEqual(monitor.ids, ["left", "right"])
        monitor.emit(["left"])
        XCTAssertTrue(model.isPausedForVisibleApp(on: "left")); XCTAssertFalse(model.isPausedForVisibleApp(on: "right"))
        XCTAssertFalse(model.isPaused, "A local monitor reason must not become a global pause")
        XCTAssertEqual(model.playbackDescription(on: "left"), "Pausado · outro app neste monitor")
        monitor.emit(["left", "right"])
        XCTAssertEqual(model.playbackDescription, "Pausado · outros apps nos monitores")
        model.togglePause()
        XCTAssertTrue(model.isPaused); XCTAssertNil(monitor.callback)
        XCTAssertEqual(model.playbackDescription(on: "left"), "Pausado por você")
        model.togglePause()
        XCTAssertEqual(monitor.starts, 2)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertNil(monitor.callback)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(monitor.starts, 3)
        _ = environment.targets.removeLast()
        model.refreshPlayback(force: false)
        XCTAssertEqual(monitor.ids, ["left"])
        monitor.emit(["left", "right"])
        XCTAssertEqual(model.visibleAppPausedDisplays, ["left"])
        model.clear(displayID: "left")
        XCTAssertNil(monitor.callback, "No assigned connected display means no polling")
        model.apply(item, to: "left")
        XCTAssertEqual(monitor.starts, 4)
        model.setPauseWhenOtherAppsVisible(false)
        XCTAssertNil(monitor.callback); XCTAssertTrue(model.visibleAppPausedDisplays.isEmpty)
        XCTAssertFalse(try store.load().settings.pauseWhenOtherAppsVisible)
        model.stop()
        XCTAssertNil(monitor.callback)
    }
}
