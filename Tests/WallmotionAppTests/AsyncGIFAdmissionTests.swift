import AppKit
import XCTest
import SwiftUI
import WallmotionCore
@testable import Wallmotion

@MainActor
final class AsyncGIFAdmissionTests: XCTestCase {
    private final class Windows {
        var values: [NSWindow] = []
        func visible(_ window: NSWindow) -> Bool {
            if !values.contains(where: { $0 === window }) { values.append(window) }
            return true
        }
    }
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [URL] = []
        func record(_ url: URL) { lock.lock();recorded.append(url);lock.unlock() }
        var urls: [URL] { lock.lock();defer { lock.unlock() };return recorded }
    }
    private struct Fixture {
        let root: URL
        let store: LibraryStore
        let photo: Wallpaper
        let gifs: [Wallpaper]
    }
    private func fixture() throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionAdmission-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        let bytes = Data([0x47,0x49,0x46,0x38,0x39,0x61,1,0,1,0,0x80,0,0,0,0,0,255,255,255,
            0x21,0xf9,4,0,10,0,0,0,0x2c,0,0,0,0,1,0,1,0,0,2,2,0x44,1,0,
            0x21,0xf9,4,0,10,0,0,0,0x2c,0,0,0,0,1,0,1,0,0,2,2,0x4c,1,0,0x3b])
        let url = root.appendingPathComponent("input.gif");try bytes.write(to: url)
        let gifs = try (0..<3).map { _ in try store.importFile(at: url) }
        let image = try GIFAnimation(data: bytes).image(at: 0)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let photoURL = root.appendingPathComponent("photo.png");try png.write(to: photoURL)
        return Fixture(root: root, store: store, photo: try store.importFile(at: photoURL), gifs: gifs)
    }
    private func screen() throws -> NSScreen {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        return screen
    }
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    func testRapidChoicesSuppressOldFailurePreserveNewSettingsAndKeepMainResponsive() async throws {
        let screen = try screen(), f = try fixture();defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try f.store.resolvedURL(for: f.gifs[0]), second = try f.store.resolvedURL(for: f.gifs[1])
        let gate = DispatchSemaphore(value: 0);defer { gate.signal() }
        let entered = expectation(description: "first structural scan blocked off main")
        let calls = Calls(), windows = Windows()
        let admissions = GIFAdmissionWorker(inspect: { url in
            XCTAssertFalse(Thread.isMainThread);calls.record(url)
            if url == first {
                entered.fulfill()
                XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
                throw LibraryError.invalidGIF
            }
            return try GIFPreflight.inspect(url: url)
        })
        let worker = GIFDecodeWorker(admissionWorker: admissions)
        let engine = DesktopCoordinator(targets: { [DesktopTarget(id: "left", screen: screen)] }, isWindowVisible: { windows.visible($0) }, gifWorker: worker)
        let initial = LibraryState(wallpapers: [f.photo] + f.gifs, assignments: ["left": f.photo.id])
        try f.store.save(initial)
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), purgeThumbnails: {},
            store: f.store, engine: engine, connectedDisplays: { [Display(id: "left", name: "Left")] })
        defer { model.stop() }
        model.refreshPlayback(force: false);try await waitUntil { windows.values.count == 1 }
        let oldWindow = try XCTUnwrap(windows.values.first)
        model.apply(f.gifs[0], to: "left")
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(model.isPreparingWallpaper(on: "left"))
        XCTAssertEqual(try f.store.load(), initial)
        XCTAssertTrue(oldWindow.isVisible)
        if let path = ProcessInfo.processInfo.environment["WALLMOTION_ADMISSION_SNAPSHOT_PATH"] {
            try await capturePending(model: model, path: path)
        }
        model.apply(f.gifs[1], to: "left");model.apply(f.gifs[2], to: "left")
        model.setAudioVolume(0.25)
        XCTAssertEqual(model.state.settings.audioVolume, 0.25, "MainActor remains usable while the scanner is blocked")
        gate.signal()
        try await waitUntil { !model.isPreparingWallpaper(on: "left") && model.activeWallpaperID(on: "left") == f.gifs[2].id }
        XCTAssertNil(model.errorMessage, "The cancelled A failure must not replace the current feedback")
        XCTAssertFalse(calls.urls.contains(second), "Cancelled queued B must not start a file-content scan")
        XCTAssertEqual(model.state.settings.audioVolume, 0.25)
        XCTAssertEqual(try f.store.load(), model.state)
        try await waitUntil { windows.values.count == 2 }
        XCTAssertFalse(oldWindow.isVisible)
    }

    func testIndependentMonitorsDoNotCancelEachOtherOrOverwriteConcurrentRename() async throws {
        let screen = try screen(), f = try fixture();defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try f.store.resolvedURL(for: f.gifs[0])
        let gate = DispatchSemaphore(value: 0);defer { gate.signal() }
        let entered = expectation(description: "left validation entered")
        let admissions = GIFAdmissionWorker(inspect: { url in
            XCTAssertFalse(Thread.isMainThread)
            if url == first { entered.fulfill();XCTAssertEqual(gate.wait(timeout: .now() + 5), .success) }
            return try GIFPreflight.inspect(url: url)
        })
        let worker = GIFDecodeWorker(limit: 128, admissionWorker: admissions)
        let engine = DesktopCoordinator(gifBudgetLimit: 16, targets: {
            [DesktopTarget(id: "left", screen: screen), DesktopTarget(id: "right", screen: screen)]
        }, isWindowVisible: { _ in true }, gifWorker: worker)
        try f.store.save(LibraryState(wallpapers: [f.photo] + f.gifs))
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), purgeThumbnails: {},
            store: f.store, engine: engine, connectedDisplays: { [Display(id: "left", name: "Left"), Display(id: "right", name: "Right")] })
        defer { model.stop() }
        model.refreshPlayback(force: false)
        model.apply(f.gifs[0], to: "left");await fulfillment(of: [entered], timeout: 2)
        model.apply(f.gifs[1], to: "right")
        XCTAssertTrue(model.rename(id: f.gifs[1].id, title: "Renamed during validation"))
        gate.signal()
        try await waitUntil { !model.isPreparingWallpaper(on: "left") && !model.isPreparingWallpaper(on: "right") }
        XCTAssertEqual(model.state.assignments, ["left": f.gifs[0].id, "right": f.gifs[1].id])
        XCTAssertEqual(model.state.wallpapers.first { $0.id == f.gifs[1].id }?.title, "Renamed during validation")
        XCTAssertEqual(try f.store.load(), model.state)
        XCTAssertNil(model.errorMessage)
    }

    func testOverBudgetAndCorruptAdmissionLeaveStoreAndOldSurfaceUntouched() async throws {
        let screen = try screen(), f = try fixture();defer { try? FileManager.default.removeItem(at: f.root) }
        let worker = GIFDecodeWorker(limit: 128, admissionWorker: GIFAdmissionWorker())
        let windows = Windows()
        let engine = DesktopCoordinator(gifBudgetLimit: 8, targets: {
            [DesktopTarget(id: "left", screen: screen), DesktopTarget(id: "right", screen: screen)]
        }, isWindowVisible: { windows.visible($0) }, gifWorker: worker)
        let initial = LibraryState(wallpapers: [f.photo] + f.gifs, assignments: ["left": f.gifs[0].id, "right": f.photo.id])
        try f.store.save(initial)
        let saved = try Data(contentsOf: f.store.stateURL)
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), purgeThumbnails: {},
            store: f.store, engine: engine, connectedDisplays: { [Display(id: "left", name: "Left"), Display(id: "right", name: "Right")] })
        defer { model.stop() }
        model.refreshPlayback(force: false);try await waitUntil { windows.values.count == 2 }
        model.apply(f.gifs[1], to: "right")
        try await waitUntil { !model.isPreparingWallpaper(on: "right") }
        XCTAssertTrue(model.errorMessage?.contains("limite global") == true)
        XCTAssertEqual(model.state, initial);XCTAssertEqual(try Data(contentsOf: f.store.stateURL), saved)
        XCTAssertEqual(windows.values.count, 2);XCTAssertTrue(windows.values.allSatisfy(\.isVisible))
        let corrupt = try f.store.resolvedURL(for: f.gifs[2]);try Data("bad".utf8).write(to: corrupt, options: .atomic)
        model.errorMessage = nil;model.apply(f.gifs[2], to: "right")
        try await waitUntil { !model.isPreparingWallpaper(on: "right") }
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.state, initial);XCTAssertEqual(try Data(contentsOf: f.store.stateURL), saved)
        XCTAssertEqual(windows.values.count, 2);XCTAssertTrue(windows.values.allSatisfy(\.isVisible))
        let attempts = await worker.decodeCount;XCTAssertEqual(attempts, 1, "Rejected metadata must not begin a native decode")
    }

    func testClearAndStopCancelLatePrePersistenceResult() async throws {
        let screen = try screen(), f = try fixture();defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = DispatchSemaphore(value: 0);defer { gate.signal() }
        let entered = expectation(description: "validation pending")
        let admissions = GIFAdmissionWorker(inspect: { url in
            entered.fulfill();XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
            return try GIFPreflight.inspect(url: url)
        })
        let engine = DesktopCoordinator(targets: { [DesktopTarget(id: "left", screen: screen)] },
            gifWorker: GIFDecodeWorker(admissionWorker: admissions))
        let initial = LibraryState(wallpapers: [f.photo] + f.gifs, assignments: ["left": f.photo.id])
        try f.store.save(initial)
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), purgeThumbnails: {},
            store: f.store, engine: engine, connectedDisplays: { [Display(id: "left", name: "Left")] })
        defer { model.stop() }
        model.refreshPlayback(force: false);model.apply(f.gifs[0], to: "left")
        await fulfillment(of: [entered], timeout: 2)
        model.clear(displayID: "left");model.stop()
        let afterClear = try Data(contentsOf: f.store.stateURL)
        gate.signal();try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(model.isPreparingWallpaper(on: "left"));XCTAssertNil(model.activeWallpaperID(on: "left"))
        XCTAssertEqual(try Data(contentsOf: f.store.stateURL), afterClear)
        XCTAssertNil(model.errorMessage)
    }

    func testConcurrentIndividuallyValidChoicesStillRespectCombinedQuota() async throws {
        let screen = try screen(), f = try fixture();defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try f.store.resolvedURL(for: f.gifs[0])
        let gate = DispatchSemaphore(value: 0);defer { gate.signal() }
        let entered = expectation(description: "first monitor scan waiting")
        let admissions = GIFAdmissionWorker(inspect: { url in
            if url == first { entered.fulfill();XCTAssertEqual(gate.wait(timeout: .now() + 5), .success) }
            return try GIFPreflight.inspect(url: url)
        })
        let engine = DesktopCoordinator(gifBudgetLimit: 8, targets: {
            [DesktopTarget(id: "left", screen: screen), DesktopTarget(id: "right", screen: screen)]
        }, gifWorker: GIFDecodeWorker(limit: 128, admissionWorker: admissions))
        try f.store.save(LibraryState(wallpapers: f.gifs))
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), purgeThumbnails: {},
            store: f.store, engine: engine, connectedDisplays: { [Display(id: "left", name: "Left"), Display(id: "right", name: "Right")] })
        defer { model.stop() }
        model.refreshPlayback(force: false);model.apply(f.gifs[0], to: "left")
        await fulfillment(of: [entered], timeout: 2)
        model.apply(f.gifs[1], to: "right");gate.signal()
        try await waitUntil { !model.isPreparingWallpaper(on: "left") && !model.isPreparingWallpaper(on: "right") }
        XCTAssertEqual(model.state.assignments.count, 1)
        XCTAssertTrue(model.errorMessage?.contains("limite global") == true)
        XCTAssertEqual(try f.store.load(), model.state)
    }

    func testIdentityChangedDuringScanIsRejectedAndNeverMemoized() async throws {
        let f = try fixture();defer { try? FileManager.default.removeItem(at: f.root) }
        let url = try f.store.resolvedURL(for: f.gifs[0]), calls = Calls()
        let bytes = try Data(contentsOf: url)
        let admissions = GIFAdmissionWorker(inspect: { url in
            XCTAssertFalse(Thread.isMainThread);calls.record(url)
            let metadata = try GIFPreflight.inspect(url: url)
            if calls.urls.count == 1 { try bytes.write(to: url, options: .atomic) }
            return metadata
        })
        do { _ = try await admissions.inspect(url: url);XCTFail("A replaced file must not be admitted under its old identity") }
        catch { XCTAssertEqual(error as? GIFAnimationError, .nativeStatus(9)) }
        let next = try await admissions.inspect(url: url)
        let cached = try await admissions.inspect(url: url)
        XCTAssertEqual(next.identity, cached.identity);XCTAssertEqual(calls.urls.count, 2)
    }

    private final class Connections { var present = true }

    func testLoadRemovalAndDisconnectInvalidatePendingValidationWithoutStaleAlerts() async throws {
        let screen = try screen()
        for action in ["load", "remove", "disconnect"] {
            let f = try fixture();defer { try? FileManager.default.removeItem(at: f.root) }
            let gate = DispatchSemaphore(value: 0);defer { gate.signal() }
            let entered = expectation(description: "pending before \(action)")
            let admissions = GIFAdmissionWorker(inspect: { url in
                entered.fulfill();XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
                return try GIFPreflight.inspect(url: url)
            })
            let connections = Connections()
            let engine = DesktopCoordinator(targets: {
                connections.present ? [DesktopTarget(id: "left", screen: screen)] : []
            }, gifWorker: GIFDecodeWorker(admissionWorker: admissions))
            let initial = LibraryState(wallpapers: [f.photo] + f.gifs, assignments: ["left": f.photo.id])
            try f.store.save(initial)
            let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), purgeThumbnails: {},
                store: f.store, engine: engine, connectedDisplays: {
                    connections.present ? [Display(id: "left", name: "Left")] : []
                })
            defer { model.stop() }
            model.refreshPlayback(force: false);model.apply(f.gifs[0], to: "left")
            await fulfillment(of: [entered], timeout: 2)
            switch action {
            case "load":
                var external = initial;external.settings.audioVolume = 0.25
                try f.store.save(external);model.load()
            case "remove": model.remove(f.gifs[0])
            default: connections.present = false;model.refreshPlayback(force: false)
            }
            let expected = model.state, saved = try Data(contentsOf: f.store.stateURL)
            gate.signal()
            _ = try await admissions.admit([:], limit: 8) // Wait for the old synchronous scan to leave its actor slot.
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertFalse(model.isPreparingWallpaper(on: "left"))
            XCTAssertEqual(model.state, expected);XCTAssertEqual(try Data(contentsOf: f.store.stateURL), saved)
            XCTAssertNil(model.errorMessage)
        }
    }

    func testModeChangeClearsErrorsFromObsoleteWholeStateAdmission() async throws {
        let screen = try screen(), f = try fixture();defer { try? FileManager.default.removeItem(at: f.root) }
        let corrupt = try f.store.resolvedURL(for: f.gifs[0])
        let windows = Windows(), engine = DesktopCoordinator(targets: {
            [DesktopTarget(id: "left", screen: screen), DesktopTarget(id: "right", screen: screen)]
        }, isWindowVisible: { windows.visible($0) }, gifWorker: GIFDecodeWorker(admissionWorker: GIFAdmissionWorker()))
        let state = LibraryState(wallpapers: [f.photo] + f.gifs, assignments: ["left": f.photo.id, "right": f.gifs[0].id])
        try f.store.save(state);try Data("bad".utf8).write(to: corrupt, options: .atomic)
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), purgeThumbnails: {},
            store: f.store, engine: engine, connectedDisplays: { [Display(id: "left", name: "Left"), Display(id: "right", name: "Right")] })
        defer { model.stop() }
        model.refreshPlayback(force: false);try await waitUntil { !model.playbackErrors.isEmpty }
        model.setDisplayMode(.mirrored, sourceDisplayID: "left")
        try await waitUntil { windows.values.count == 2 }
        XCTAssertTrue(model.playbackErrors.isEmpty)
        XCTAssertEqual(model.state.mirroredWallpaperID, f.photo.id)
    }

    private func capturePending(model: LibraryModel, path: String) async throws {
        let hosting = NSHostingView(rootView: LibraryView(model: model))
        let bounds = CGRect(x: 0,y: 0,width: 1120,height: 760)
        hosting.appearance = NSAppearance(named: .darkAqua);hosting.frame = bounds
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false;window.contentView = hosting
        window.setFrameOrigin(CGPoint(x: -10000,y: -10000));window.orderBack(nil)
        defer { window.orderOut(nil);window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let bitmap = try await LibrarySnapshotCapture.capture(hosting)
        let destination = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination)
    }

    func testInitialRestoredAssignmentRunsStructuralScanOffMainAndRespectsLatestPause() async throws {
        let screen = try screen(), f = try fixture();defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = DispatchSemaphore(value: 0);defer { gate.signal() }
        let entered = expectation(description: "restored GIF structural scan entered off main")
        let admissions = GIFAdmissionWorker(inspect: { url in
            XCTAssertFalse(Thread.isMainThread);entered.fulfill()
            XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
            return try GIFPreflight.inspect(url: url)
        })
        let windows = Windows()
        let engine = DesktopCoordinator(targets: { [DesktopTarget(id: "left", screen: screen)] },
            isWindowVisible: { windows.visible($0) }, gifWorker: GIFDecodeWorker(admissionWorker: admissions))
        let state = LibraryState(wallpapers: f.gifs, assignments: ["left": f.gifs[0].id])
        try f.store.save(state)
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), purgeThumbnails: {},
            store: f.store, engine: engine, connectedDisplays: { [Display(id: "left", name: "Left")] })
        defer { model.stop() }
        model.refreshPlayback(force: false);await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(windows.values.isEmpty)
        model.togglePause();XCTAssertTrue(model.isPaused)
        gate.signal();try await waitUntil { windows.values.count == 1 }
        let surface = try XCTUnwrap(windows.values.first?.contentView as? ImageSurface)
        XCTAssertFalse(surface.gifIsPlaying)
    }
}
