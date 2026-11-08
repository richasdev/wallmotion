import AppKit
import AVFoundation
import XCTest
import WallmotionCore
@testable import Wallmotion

@MainActor
final class MonitorIsolationTests: XCTestCase {
    @MainActor private final class Environment {
        var targets: [DesktopTarget]
        var windows: [NSWindow] = []
        init(screen: NSScreen) {
            targets = [
                DesktopTarget(id: "left", screen: screen, frame: CGRect(x: -10000, y: -10000, width: 160, height: 90)),
                DesktopTarget(id: "right", screen: screen, frame: CGRect(x: -9800, y: -10000, width: 160, height: 90))
            ]
        }
        func visible(_ window: NSWindow) -> Bool {
            if !windows.contains(where: { $0 === window }) { windows.append(window) }
            return true
        }
        func active(_ id: String) -> NSWindow? {
            let x: CGFloat = id == "left" ? -10000 : -9800
            return windows.last { $0.frame.minX == x && $0.contentView != nil }
        }
        func player(_ id: String) -> AVPlayer? { (active(id)?.contentView as? VideoSurface)?.playerLayer.player }
    }

    @MainActor private final class Fixture {
        let root: URL
        let store: LibraryStore
        let first: Wallpaper, second: Wallpaper, third: Wallpaper, photo: Wallpaper
        let environment: Environment
        let model: LibraryModel

        init() async throws {
            _ = NSApplication.shared
            guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionMonitorIsolation-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = root.appendingPathComponent("generated.mp4")
            try await LocalVideoFixture.write(at: url, frames: 90, fps: 3)
            let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
            let first = try store.importFile(at: url), second = try store.importFile(at: url), third = try store.importFile(at: url)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let color = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1)
            for x in 0..<2 { for y in 0..<2 { bitmap.setColor(color, atX: x, y: y) } }
            let photoURL = root.appendingPathComponent("photo.png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: photoURL)
            let photo = try store.importFile(at: photoURL)
            var initial = LibraryState(wallpapers: [first, second, third, photo], assignments: ["left": first.id, "right": second.id],
                settings: .init(pauseOnLowPower: false, audioDisplayID: "left", audioVolume: 0.6))
            initial.setMediaFit(.center, for: first.id, on: "left")
            initial.setMediaFit(.fill, for: second.id, on: "right")
            try store.save(initial)
            let environment = Environment(screen: screen)
            let engine = DesktopCoordinator(targets: { environment.targets }, isWindowVisible: { environment.visible($0) }, sharedVideoLayerReady: { _ in true })
            let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), purgeThumbnails: {},
                store: store, engine: engine, connectedDisplays: { environment.targets.map { Display(id: $0.id, name: $0.id) } })
            self.root = root; self.store = store; self.first = first; self.second = second; self.third = third; self.photo = photo
            self.environment = environment; self.model = model
            model.refreshPlayback(force: false)
        }

        func close() { model.stop(); try? FileManager.default.removeItem(at: root) }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    func testIndependentApplyFitAndClearOnlyTouchSelectedRuntimeAndKeepOtherVideoAdvancing() async throws {
        let f = try await Fixture(); defer { f.close() }
        let model = f.model, environment = f.environment
        try await waitUntil { environment.player("left")?.timeControlStatus == .playing && environment.player("right")?.timeControlStatus == .playing }
        let rightWindow = try XCTUnwrap(environment.active("right")), right = try XCTUnwrap(environment.player("right"))
        let rightItem = try XCTUnwrap(right.currentItem), rightFit = model.mediaFit(on: "right")
        let previousLeft = try XCTUnwrap(environment.player("left")), before = right.currentTime().seconds
        model.apply(f.third, to: "left")
        try await waitUntil { environment.player("left")?.timeControlStatus == .playing && environment.player("left") !== previousLeft }
        let left = try XCTUnwrap(environment.player("left")), leftWindow = try XCTUnwrap(environment.active("left"))
        model.setMediaFit(.stretch, on: "left")
        try await waitUntil { (leftWindow.contentView as? VideoSurface)?.playerLayer.videoGravity == .resize }
        XCTAssertTrue(environment.player("left") === left, "Framing is a geometry update")
        XCTAssertTrue(environment.active("right") === rightWindow)
        XCTAssertTrue(environment.player("right") === right)
        XCTAssertTrue(right.currentItem === rightItem)
        XCTAssertEqual(model.activeWallpaperID(on: "right"), f.second.id)
        XCTAssertEqual(model.mediaFit(on: "right"), rightFit)
        model.clear(displayID: "left")
        try await waitUntil { environment.active("left") == nil }
        XCTAssertNil(left.currentItem)
        XCTAssertTrue(environment.active("right") === rightWindow)
        XCTAssertTrue(right.currentItem === rightItem)
        XCTAssertEqual(right.rate, 1)
        try await waitUntil { right.currentTime().seconds > before + 0.05 }
        XCTAssertEqual(model.state.assignments, ["right": f.second.id])
        XCTAssertEqual(model.state.mediaFit(for: f.first.id, on: "left"), .center)
        XCTAssertEqual(model.state.mediaFit(for: f.third.id, on: "left"), .stretch)
        XCTAssertEqual(try f.store.load(), model.state)
    }

    func testExplicitSeparateControlRestoresChoicesAfterMirrorPanoramaAndHotplug() async throws {
        let f = try await Fixture(); defer { f.close() }
        let model = f.model, environment = f.environment
        let assignments = model.state.assignments, fits = model.state.mediaFits
        try await waitUntil { environment.player("left")?.timeControlStatus == .playing && environment.player("right")?.timeControlStatus == .playing }
        for mode in [DisplayMode.mirrored, .spanned] {
            model.setDisplayMode(mode, sourceDisplayID: "left")
            try await waitUntil {
                guard let left = environment.player("left"), let right = environment.player("right") else { return false }
                return left === right && left.timeControlStatus == .playing
            }
            let shared = try XCTUnwrap(environment.player("left"))
            model.apply(f.third, to: "right")
            model.setMediaFit(.stretch, on: "right")
            try await waitUntil { environment.player("left") !== shared && environment.player("left")?.timeControlStatus == .playing }
            XCTAssertEqual(model.activeWallpaperID(on: "left"), f.third.id)
            XCTAssertEqual(model.activeWallpaperID(on: "right"), f.third.id)
            XCTAssertEqual(model.state.assignments, assignments)
            XCTAssertEqual(model.state.mediaFits, fits)
            model.useIndependentDisplays(on: "right")
            try await waitUntil {
                guard let left = environment.player("left"), let right = environment.player("right") else { return false }
                return left !== right && left.timeControlStatus == .playing && right.timeControlStatus == .playing
            }
            XCTAssertEqual(model.state.displayMode, .independent)
            XCTAssertEqual(model.activeWallpaperID(on: "left"), f.first.id)
            XCTAssertEqual(model.activeWallpaperID(on: "right"), f.second.id)
            XCTAssertEqual(model.mediaFit(on: "left"), .center)
            XCTAssertEqual(model.mediaFit(on: "right"), .fill)
        }
        let leftWindow = try XCTUnwrap(environment.active("left")), left = try XCTUnwrap(environment.player("left"))
        let right = try XCTUnwrap(environment.player("right")), target = environment.targets.removeLast()
        model.refreshPlayback(force: false)
        try await waitUntil { environment.active("right") == nil }
        XCTAssertNil(right.currentItem)
        XCTAssertTrue(environment.active("left") === leftWindow)
        XCTAssertTrue(environment.player("left") === left)
        let disconnectedState = model.state
        model.useIndependentDisplays(on: "right")
        model.clear(displayID: "right")
        XCTAssertEqual(model.state, disconnectedState)
        XCTAssertFalse(model.setAudioEnabled(true, on: "right"))
        environment.targets.append(target)
        model.refreshPlayback(force: false)
        try await waitUntil { environment.player("right")?.timeControlStatus == .playing }
        XCTAssertTrue(environment.active("left") === leftWindow)
        XCTAssertEqual(model.state.assignments, assignments)
        XCTAssertEqual(model.state.mediaFits, fits)
        XCTAssertEqual(model.activeWallpaperID(on: "right"), f.second.id)
        XCTAssertEqual(model.mediaFit(on: "right"), .fill)
        XCTAssertEqual(try f.store.load(), model.state)
    }

    func testMonitorSoundTransfersOnlyOwnerAndMutingAnotherMonitorNeverMutesCurrentSource() async throws {
        let f = try await Fixture(); defer { f.close() }
        let model = f.model, environment = f.environment
        try await waitUntil { environment.player("left")?.timeControlStatus == .playing && environment.player("right")?.timeControlStatus == .playing }
        let left = try XCTUnwrap(environment.player("left")), right = try XCTUnwrap(environment.player("right"))
        let leftItem = try XCTUnwrap(left.currentItem), rightItem = try XCTUnwrap(right.currentItem)
        let count = environment.windows.count
        XCTAssertTrue(model.setAudioEnabled(false, on: "right"))
        XCTAssertEqual(model.state.settings.audioDisplayID, "left")
        XCTAssertEqual(left.volume, 0.6, accuracy: 0.0001)
        XCTAssertTrue(model.setAudioEnabled(true, on: "right"))
        XCTAssertEqual(model.state.settings.audioDisplayID, "right")
        XCTAssertTrue(left.isMuted); XCTAssertEqual(left.volume, 0)
        XCTAssertFalse(right.isMuted); XCTAssertEqual(right.volume, 0.6, accuracy: 0.0001)
        XCTAssertTrue(model.setAudioEnabled(false, on: "left"))
        XCTAssertFalse(right.isMuted)
        XCTAssertTrue(model.setAudioEnabled(true, on: "right"))
        XCTAssertFalse(model.setAudioEnabled(true, on: "missing"))
        XCTAssertFalse(model.setAudioEnabled(false, on: "missing"))
        XCTAssertEqual(model.state.settings.audioDisplayID, "right")
        XCTAssertTrue(model.setAudioEnabled(false, on: "right"))
        XCTAssertNil(model.state.settings.audioDisplayID)
        XCTAssertTrue(left.isMuted); XCTAssertTrue(right.isMuted)
        XCTAssertEqual(environment.windows.count, count)
        XCTAssertTrue(left.currentItem === leftItem); XCTAssertTrue(right.currentItem === rightItem)
        XCTAssertEqual(model.state.settings.audioVolume, 0.6)
        XCTAssertEqual(model.state.displayMode, .independent)
        XCTAssertEqual(try f.store.load(), model.state)
    }

    func testSeparateControlStillValidatesRestoredGIFBeforeLeavingSharedScene() async throws {
        let f = try await Fixture(); defer { f.close() }
        let model = f.model, environment = f.environment
        let broken = Wallpaper(title: "Invalid private fixture", kind: .gif, source: .local(filename: "broken.gif"))
        try Data("invalid gif".utf8).write(to: f.store.mediaDirectory.appendingPathComponent("broken.gif"))
        var shared = model.state
        shared.wallpapers.append(broken)
        shared.assignments["right"] = broken.id
        shared.displayMode = .mirrored
        shared.mirroredWallpaperID = f.first.id
        try f.store.save(shared)
        model.load(); model.refreshPlayback(force: false)
        try await waitUntil {
            guard let left = environment.player("left"), let right = environment.player("right") else { return false }
            return left === right && left.timeControlStatus == .playing
        }
        let player = try XCTUnwrap(environment.player("left")), count = environment.windows.count
        model.useIndependentDisplays(on: "right")
        try await waitUntil { !model.isPreparingWallpaper(on: "right") }
        XCTAssertEqual(model.state, shared)
        XCTAssertEqual(try f.store.load(), shared)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(environment.windows.count, count)
        XCTAssertTrue(environment.player("left") === player)
        XCTAssertTrue(environment.player("right") === player)
        XCTAssertEqual(player.rate, 1)
    }

    func testSoundRejectsPhotosButCanDetachStaleOwnerAndFailedSaveLeavesRuntimeUnchanged() async throws {
        let f = try await Fixture(); defer { f.close() }
        let model = f.model, environment = f.environment
        try await waitUntil { environment.player("left")?.timeControlStatus == .playing && environment.player("right")?.timeControlStatus == .playing }
        XCTAssertTrue(model.setAudioEnabled(true, on: "right"))
        model.apply(f.photo, to: "right")
        try await waitUntil { environment.active("right")?.contentView is ImageSurface }
        XCTAssertFalse(model.setAudioEnabled(true, on: "right"))
        XCTAssertEqual(model.state.settings.audioDisplayID, "right")
        XCTAssertTrue(model.setAudioEnabled(false, on: "right"))
        XCTAssertNil(model.state.settings.audioDisplayID)
        let before = model.state, left = try XCTUnwrap(environment.player("left"))
        try FileManager.default.removeItem(at: f.store.stateURL)
        try FileManager.default.createDirectory(at: f.store.stateURL, withIntermediateDirectories: false)
        XCTAssertFalse(model.setAudioEnabled(true, on: "left"))
        XCTAssertEqual(model.state, before)
        XCTAssertTrue(left.isMuted); XCTAssertEqual(left.volume, 0)
        XCTAssertNotNil(model.errorMessage)
    }

    func testExplicitSeparateControlRejectsDisconnectedTargetsAndReadOnlyLibrary() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionMonitorReadOnly-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let item = try Wallpaper.remote("https://example.invalid/video.mp4")
        let initial = LibraryState(wallpapers: [item], assignments: ["left": item.id], displayMode: .mirrored, mirroredWallpaperID: item.id)
        try store.save(initial)
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store,
            engine: DesktopCoordinator(targets: { [] }), connectedDisplays: { [Display(id: "left", name: "Left")] })
        defer { model.stop() }
        model.refreshPlayback(force: false)
        model.useIndependentDisplays(on: "disconnected")
        model.clear(displayID: "disconnected")
        XCTAssertEqual(model.state, initial)
        let corrupt = Data("{ broken".utf8)
        try corrupt.write(to: store.stateURL)
        model.load()
        XCTAssertFalse(model.canEdit)
        model.useIndependentDisplays(on: "left")
        XCTAssertFalse(model.setAudioEnabled(true, on: "left"))
        XCTAssertFalse(model.setAudioEnabled(false, on: "left"))
        XCTAssertEqual(model.state, initial)
        XCTAssertEqual(try Data(contentsOf: store.stateURL), corrupt)
    }
}
