import AppKit
import SwiftUI
import XCTest
import WallmotionCore
@testable import Wallmotion

private actor TestAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: true)
        pending.forEach { $0.resume() }
    }
}

@MainActor
final class LibraryModelTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionModelTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writePhoto(to url: URL) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        for x in 0..<2 {
            for y in 0..<2 { bitmap.setColor(NSColor(deviceRed: 0.2, green: 0.4, blue: 0.9, alpha: 1), atX: x, y: y) }
        }
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try bytes.write(to: url)
        return bytes
    }

    func testCorruptLibraryDisablesEditingAndPreservesOriginalBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(rootURL: directory)
        let original = Data("{\"version\": 1, corrupt".utf8)
        try original.write(to: store.stateURL)
        let model = LibraryModel(store: store)
        defer { model.stop() }

        XCTAssertFalse(model.canEdit)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.errorMessage?.contains(store.stateURL.path) == true)
        XCTAssertFalse(model.addURL("https://cdn.example.com/video.mp4"))
        model.togglePause()
        model.setPauseOnLowPower(false)
        XCTAssertTrue(model.state.wallpapers.isEmpty)
        XCTAssertEqual(model.state.settings, PlaybackSettings())
        XCTAssertEqual(try Data(contentsOf: store.stateURL), original)
    }

    func testLibraryAndPlaybackPreferencesPersistAcrossModelInstances() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(rootURL: directory)
        let model = LibraryModel(store: store)
        defer { model.stop() }
        XCTAssertTrue(model.addURL("https://cdn.example.com/live.m3u8?token=a%2Fb"))
        model.togglePause()
        model.setPauseOnLowPower(false)
        XCTAssertTrue(model.isPaused)
        XCTAssertTrue(model.state.settings.isManuallyPaused)
        XCTAssertFalse(model.state.settings.pauseOnLowPower)
        let persisted = try store.load()
        XCTAssertEqual(persisted, model.state)

        let restored = LibraryModel(store: store)
        defer { restored.stop() }
        XCTAssertTrue(restored.canEdit)
        XCTAssertNil(restored.errorMessage)
        XCTAssertEqual(restored.state, persisted)
        XCTAssertTrue(restored.isPaused)
        XCTAssertEqual(restored.state.wallpapers.first?.source, .remote(url: URL(string: "https://cdn.example.com/live.m3u8?token=a%2Fb")!))
        XCTAssertNil(restored.localMediaURL(for: try XCTUnwrap(restored.state.wallpapers.first)))
    }

    func testMediaFitPersistsForEachWallpaperOnTheSelectedDisplay() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let screen = NSScreen.screens.first, let displayID = Display.identify(screen) else {
            throw XCTSkip("A seleção de monitor requer uma sessão gráfica.")
        }
        let store = LibraryStore(rootURL: directory.appendingPathComponent("Library"))
        let photo = directory.appendingPathComponent("photo.png")
        _ = try writePhoto(to: photo)
        let model = LibraryModel(store: store)
        defer { model.stop() }
        await model.importFiles([photo, photo])
        model.refreshPlayback(force: false)
        let first = model.state.wallpapers[0]
        let second = model.state.wallpapers[1]
        model.apply(first, to: displayID)
        model.setMediaFit(.fill, on: displayID)
        model.apply(second, to: displayID)
        XCTAssertEqual(model.state.mediaFit(for: second.id, on: displayID), .fit)
        model.apply(first, to: displayID)
        XCTAssertEqual(model.state.mediaFit(for: first.id, on: displayID), .fill)
        let restored = LibraryModel(store: store)
        defer { restored.stop() }
        XCTAssertEqual(restored.state.mediaFit(for: first.id, on: displayID), .fill)
        XCTAssertEqual(try store.load(), model.state)
        model.clear(displayID: displayID)
        XCTAssertEqual(model.state.mediaFit(for: first.id, on: displayID), .fill)
        XCTAssertNil(model.errorMessage)
    }

    func testAsyncImportAndRemovalOnlyDeleteTheLibraryCopy() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(rootURL: directory.appendingPathComponent("Library", isDirectory: true))
        let source = directory.appendingPathComponent("Original photo.png")
        let originalBytes = try writePhoto(to: source)
        let model = LibraryModel(store: store)
        defer { model.stop() }
        await model.importFiles([source])

        XCTAssertFalse(model.isImporting)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.state.wallpapers.count, 1)
        let imported = try XCTUnwrap(model.state.wallpapers.first)
        let copy = try store.resolvedURL(for: imported)
        XCTAssertEqual(model.localMediaURL(for: imported), copy)
        XCTAssertNotEqual(copy, source)
        XCTAssertEqual(copy.deletingLastPathComponent(), store.mediaDirectory)
        XCTAssertEqual(try Data(contentsOf: copy), originalBytes)
        XCTAssertEqual(try store.load(), model.state)

        model.remove(imported)
        XCTAssertTrue(model.state.wallpapers.isEmpty)
        XCTAssertTrue(model.state.assignments.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        XCTAssertTrue(try store.load().wallpapers.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testImportQueuesConcurrentSelectionsAndKeepsValidDuplicatesAndOriginals() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(rootURL: directory.appendingPathComponent("Library", isDirectory: true))
        let source = directory.appendingPathComponent("Selecionada.png")
        let originalBytes = try writePhoto(to: source)
        let folder = directory.appendingPathComponent("Pasta", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unsupported = directory.appendingPathComponent("notas.txt")
        try Data("texto".utf8).write(to: unsupported)
        let model = LibraryModel(store: store)
        defer { model.stop() }

        let firstSelection = Task { await model.importFiles([source]) }
        await Task.yield()
        await model.importFiles([folder, source, unsupported])
        await firstSelection.value

        XCTAssertFalse(model.isImporting)
        XCTAssertEqual(model.state.wallpapers.count, 2)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        let copies = try model.state.wallpapers.map { try store.resolvedURL(for: $0) }
        XCTAssertEqual(Set(copies).count, 2)
        for copy in copies { XCTAssertEqual(try Data(contentsOf: copy), originalBytes) }
    }

    func testImportDrainsSelectionQueuedDuringFailedSaveRollback() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(rootURL: directory.appendingPathComponent("Library", isDirectory: true))
        let failedSource = directory.appendingPathComponent("Rollback.png")
        let failedBytes = try writePhoto(to: failedSource)
        let queuedSource = directory.appendingPathComponent("Queued.png")
        let queuedBytes = try writePhoto(to: queuedSource)
        let cleanupStarted = TestAsyncGate()
        let finishCleanup = TestAsyncGate()
        let model = LibraryModel(store: store, beforeRollbackCleanup: {
            await cleanupStarted.open()
            await finishCleanup.wait()
        })
        defer { model.stop() }

        // Replacing the not-yet-created state file path with a directory makes save fail
        // after the first media copy, forcing the asynchronous rollback path.
        try FileManager.default.createDirectory(at: store.stateURL, withIntermediateDirectories: true)
        let failedSelection = Task { await model.importFiles([failedSource]) }
        await cleanupStarted.wait()

        let queuedSelection = Task { await model.importFiles([queuedSource]) }
        let deadline = ContinuousClock.now + .seconds(5)
        while model.queuedImportCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let selectionWasQueuedDuringCleanup = model.queuedImportCount == 1

        try FileManager.default.removeItem(at: store.stateURL)
        await finishCleanup.open()
        await failedSelection.value
        await queuedSelection.value

        XCTAssertTrue(selectionWasQueuedDuringCleanup, "A second selection must reach the queue before rollback finishes.")
        XCTAssertFalse(model.isImporting)
        XCTAssertEqual(model.state.wallpapers.map(\.title), ["Queued"])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try Data(contentsOf: failedSource), failedBytes)
        XCTAssertEqual(try Data(contentsOf: queuedSource), queuedBytes)
        XCTAssertEqual(try store.load(), model.state)
        let mediaFiles = try FileManager.default.contentsOfDirectory(at: store.mediaDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(mediaFiles.count, 1, "Rollback removes the failed copy while the queued import persists its own copy.")
    }

    func testRejectedGIFSelectionPreservesPersistedAssignmentAndOtherMonitors() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let screen = NSScreen.screens.first, let displayID = Display.identify(screen) else {
            throw XCTSkip("É necessário um display para validar a seleção.")
        }
        let store = LibraryStore(rootURL: directory.appendingPathComponent("Library"))
        let photoURL = directory.appendingPathComponent("photo.png")
        _ = try writePhoto(to: photoURL)
        let photo = try store.importFile(at: photoURL)
        let gifURL = directory.appendingPathComponent("animation.gif")
        let gif = Data([
            0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0, 0x80, 0, 0,
            0, 0, 0, 0xff, 0xff, 0xff,
            0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 1, 0, 0x3b
        ])
        try gif.write(to: gifURL)
        let animation = try store.importFile(at: gifURL)
        let initial = LibraryState(wallpapers: [photo, animation],
                                   assignments: [displayID: photo.id, "disconnected": animation.id])
        try store.save(initial)
        let savedBytes = try Data(contentsOf: store.stateURL)
        let engine = DesktopCoordinator(gifBudgetLimit: 0)
        let model = LibraryModel(store: store, engine: engine)
        defer { model.stop() }
        model.refreshPlayback(force: false)
        model.apply(animation, to: displayID)
        XCTAssertTrue(model.errorMessage?.contains("limite global") == true)
        XCTAssertEqual(model.state, initial)
        XCTAssertEqual(try Data(contentsOf: store.stateURL), savedBytes)
        XCTAssertEqual(engine.gifBudget.totalBytes, 0)
        model.apply(animation, to: "unknown")
        XCTAssertEqual(model.state, initial)
    }

    func testSaveFailureDoesNotReserveGIFQuotaOrChangeSelection() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let screen = NSScreen.screens.first, let displayID = Display.identify(screen) else {
            throw XCTSkip("É necessário um display para validar a seleção.")
        }
        let store = LibraryStore(rootURL: directory.appendingPathComponent("Library"))
        let url = directory.appendingPathComponent("one.gif")
        try Data([
            0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0, 0x80, 0, 0,
            0, 0, 0, 0xff, 0xff, 0xff,
            0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 1, 0, 0x3b
        ]).write(to: url)
        let item = try store.importFile(at: url)
        let state = LibraryState(wallpapers: [item])
        try store.save(state)
        let engine = DesktopCoordinator(gifBudgetLimit: 4)
        let model = LibraryModel(store: store, engine: engine)
        defer { model.stop() }
        model.refreshPlayback(force: false)
        try FileManager.default.removeItem(at: store.stateURL)
        try FileManager.default.createDirectory(at: store.stateURL, withIntermediateDirectories: false)
        model.apply(item, to: displayID)
        XCTAssertTrue(model.errorMessage?.contains("salvar") == true)
        XCTAssertEqual(model.state, state)
        XCTAssertEqual(engine.gifBudget.totalBytes, 0)
    }

    func testOptionalLibraryViewSnapshotUsesOnlyTemporaryFixtures() async throws {
        guard let path = ProcessInfo.processInfo.environment["WALLMOTION_SNAPSHOT_PATH"], !path.isEmpty else {
            throw XCTSkip("Defina WALLMOTION_SNAPSHOT_PATH para exportar o snapshot de QA.")
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(rootURL: directory.appendingPathComponent("Library", isDirectory: true))
        let model = LibraryModel(store: store)
        defer { model.stop() }
        let photo = directory.appendingPathComponent("Montanhas ao amanhecer.png")
        _ = try writePhoto(to: photo)
        await model.importFiles([photo])
        XCTAssertTrue(model.addURL("https://media.example.com/Oceano.mp4"))
        XCTAssertTrue(model.addURL("https://media.example.com/Cidade-noturna.m3u8"))
        model.refreshPlayback(force: false)

        if let display = model.displays.first, let photo = model.state.wallpapers.first {
            model.apply(photo, to: display.id)
            model.setMediaFit(.fill, on: display.id)
        }
        let bounds = NSRect(x: 0, y: 0, width: 1120, height: 760)
        let hosting = NSHostingView(rootView: LibraryView(model: model))
        hosting.frame = bounds
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let destination = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: destination, options: .atomic)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
    }
}
