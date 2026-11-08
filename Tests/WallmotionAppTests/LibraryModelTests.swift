import AppKit
import ScreenCaptureKit
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
    private func waitForAdmission(_ model: LibraryModel, on display: String) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while model.isPreparingWallpaper(on: display), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isPreparingWallpaper(on: display))
    }

    @MainActor private final class TestDisplays {
        var values: [Display]
        init(_ values: [Display]) { self.values = values }
    }

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
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store)
        defer { model.stop() }

        XCTAssertFalse(model.canEdit)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.errorMessage?.contains(store.stateURL.path) == true)
        XCTAssertFalse(model.addURL("https://cdn.example.com/video.mp4"))
        model.togglePause()
        model.setPauseOnLowPower(false)
        model.setPauseOnThermalPressure(false)
        XCTAssertFalse(model.rename(id: UUID(), title: "Preserved"))
        XCTAssertTrue(model.state.wallpapers.isEmpty)
        XCTAssertEqual(model.state.settings, PlaybackSettings())
        XCTAssertEqual(try Data(contentsOf: store.stateURL), original)
    }

    func testLibraryAndPlaybackPreferencesPersistAcrossModelInstances() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(rootURL: directory)
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store)
        defer { model.stop() }
        XCTAssertTrue(model.addURL("https://cdn.example.com/live.m3u8?token=a%2Fb"))
        model.togglePause()
        model.setPauseOnLowPower(false)
        XCTAssertTrue(model.isPaused)
        XCTAssertTrue(model.state.settings.isManuallyPaused)
        XCTAssertFalse(model.state.settings.pauseOnLowPower)
        let persisted = try store.load()
        XCTAssertEqual(persisted, model.state)

        let restored = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store)
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
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store)
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
        let restored = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store)
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
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store)
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

    func testRemovingOneOfTwoValidEntriesPreservesSharedCopyUntilLastReference() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(rootURL: directory.appendingPathComponent("Library", isDirectory: true))
        let source = directory.appendingPathComponent("Original.png")
        let original = try writePhoto(to: source)
        let first = try store.importFile(at: source)
        let second = Wallpaper(title: "Second reference", kind: first.kind, source: first.source)
        let initial = LibraryState(wallpapers: [first, second], assignments: ["fixture": second.id])
        try store.save(initial) // Shared filename is accepted by the persisted-state contract.
        let copy = try store.resolvedURL(for: second)
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store, engine: DesktopCoordinator(targets: { [] }), connectedDisplays: { [] })
        defer { model.stop() }
        model.remove(first)
        XCTAssertEqual(model.state.wallpapers.map(\.id), [second.id])
        XCTAssertEqual(model.state.assignments, ["fixture": second.id])
        guard FileManager.default.fileExists(atPath: copy.path) else { return XCTFail("Removing one valid entry deleted another entry's managed file") }
        XCTAssertEqual(try Data(contentsOf: copy), original)
        model.remove(second)
        XCTAssertTrue(model.state.wallpapers.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertNil(model.errorMessage)
    }

    func testRemovingMissingIDIsNoOpAndDoesNotDeleteItsSuppliedSource() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(rootURL: directory.appendingPathComponent("Library", isDirectory: true))
        let source = directory.appendingPathComponent("Original.png")
        _ = try writePhoto(to: source)
        let current = try store.importFile(at: source)
        let initial = LibraryState(wallpapers: [current])
        try store.save(initial)
        let before = try Data(contentsOf: store.stateURL)
        let copy = try store.resolvedURL(for: current)
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store, engine: DesktopCoordinator(targets: { [] }), connectedDisplays: { [] })
        defer { model.stop() }
        let missing = Wallpaper(title: "Already removed", kind: .image, source: current.source)
        model.remove(missing)
        XCTAssertEqual(model.state, initial)
        XCTAssertEqual(try Data(contentsOf: store.stateURL), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertNil(model.errorMessage)
    }

    func testRemovalUsesCurrentRecordInsteadOfStaleCallerSourceAndFailedSaveKeepsCopies() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(rootURL: directory.appendingPathComponent("Library", isDirectory: true))
        let firstSource = directory.appendingPathComponent("First.png")
        let nextSource = directory.appendingPathComponent("Next.png")
        _ = try writePhoto(to: firstSource)
        _ = try writePhoto(to: nextSource)
        let stale = try store.importFile(at: firstSource)
        let imported = try store.importFile(at: nextSource)
        let firstCopy = try store.resolvedURL(for: stale)
        let currentCopy = try store.resolvedURL(for: imported)
        var current = stale
        current.source = imported.source
        try store.save(LibraryState(wallpapers: [current]))
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store, engine: DesktopCoordinator(targets: { [] }), connectedDisplays: { [] })
        defer { model.stop() }
        let saved = try Data(contentsOf: store.stateURL)
        try FileManager.default.removeItem(at: store.stateURL)
        try FileManager.default.createDirectory(at: store.stateURL, withIntermediateDirectories: false)
        model.remove(stale)
        XCTAssertEqual(model.state.wallpapers, [current])
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstCopy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentCopy.path))
        try FileManager.default.removeItem(at: store.stateURL)
        try saved.write(to: store.stateURL)
        model.errorMessage = nil
        model.remove(stale)
        XCTAssertTrue(model.state.wallpapers.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentCopy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstCopy.path), "A stale source supplied by the caller must not select the physical file to delete.")
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
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store)
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
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store, beforeRollbackCleanup: {
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

    func testOversizeImportBatchIsRejectedAtomicallyAndNextCycleCanImport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(rootURL: directory.appendingPathComponent("Library", isDirectory: true))
        let source = directory.appendingPathComponent("Source.png")
        let original = try writePhoto(to: source)
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store, connectedDisplays: { [] })
        defer { model.stop() }
        await model.importFiles(Array(repeating: source, count: LibraryModel.maximumImportURLsPerCycle + 1))
        XCTAssertFalse(model.isImporting)
        XCTAssertEqual(model.queuedImportCount, 0)
        XCTAssertTrue(model.state.wallpapers.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.mediaDirectory.path))
        XCTAssertTrue(model.errorMessage?.contains("256") == true)
        model.errorMessage = nil
        await model.importFiles([source])
        XCTAssertEqual(model.state.wallpapers.count, 1)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testImportCycleBudgetIncludesActiveBatchDuringRollbackAndResets() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(rootURL: directory.appendingPathComponent("Library", isDirectory: true))
        let source = directory.appendingPathComponent("Source.png")
        _ = try writePhoto(to: source)
        let cleanupStarted = TestAsyncGate()
        let finishCleanup = TestAsyncGate()
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store, connectedDisplays: { [] }, beforeRollbackCleanup: {
            await cleanupStarted.open()
            await finishCleanup.wait()
        })
        defer { model.stop() }
        try FileManager.default.createDirectory(at: store.stateURL, withIntermediateDirectories: true)
        let active = Task { await model.importFiles([source]) }
        await cleanupStarted.wait()
        let unsupported = directory.appendingPathComponent("unsupported.txt")
        let queuedCount = LibraryModel.maximumImportURLsPerCycle - 1
        let queued = Task { await model.importFiles(Array(repeating: unsupported, count: queuedCount)) }
        let deadline = ContinuousClock.now + .seconds(5)
        while model.queuedImportCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(model.queuedImportCount, queuedCount)
        await model.importFiles([source]) // Exceeds total even though only 255 are pending.
        XCTAssertEqual(model.queuedImportCount, queuedCount)
        XCTAssertTrue(model.errorMessage?.contains("256") == true)
        try FileManager.default.removeItem(at: store.stateURL)
        await finishCleanup.open()
        await active.value
        await queued.value
        XCTAssertFalse(model.isImporting)
        XCTAssertTrue(model.state.wallpapers.isEmpty)
        XCTAssertTrue(model.errorMessage?.contains("245") == true)
        XCTAssertTrue(model.errorMessage?.contains("256") == true, "The rejected batch warning survives the accepted cycle.")
        model.errorMessage = nil
        await model.importFiles([source])
        XCTAssertEqual(model.state.wallpapers.count, 1)
        XCTAssertNil(model.errorMessage)
    }

    func testImportFailureSummaryBoundsDetailsByUTF8BytesAndCountsRemainder() {
        var failures = ImportFailureSummary()
        let oversized = String(repeating: "🌅", count: 1000)
        for _ in 0..<256 { failures.append(oversized) }
        XCTAssertEqual(failures.count, 256)
        XCTAssertEqual(failures.details.count, 10)
        XCTAssertTrue(failures.details.allSatisfy { $0.utf8.count <= 1024 && $0.hasSuffix("…") && !$0.contains("�") })
        XCTAssertTrue(failures.message?.contains("246") == true)
        XCTAssertLessThanOrEqual(failures.message?.utf8.count ?? Int.max, 11_000)
    }

    func testRejectedGIFSelectionPreservesPersistedAssignmentAndOtherMonitors() async throws {
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
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store, engine: engine)
        defer { model.stop() }
        model.refreshPlayback(force: false)
        model.apply(animation, to: displayID)
        try await waitForAdmission(model, on: displayID)
        XCTAssertTrue(model.errorMessage?.contains("limite global") == true)
        XCTAssertEqual(model.state, initial)
        XCTAssertEqual(try Data(contentsOf: store.stateURL), savedBytes)
        XCTAssertEqual(engine.gifBudget.totalBytes, 0)
        model.apply(animation, to: "unknown")
        XCTAssertEqual(model.state, initial)
    }

    func testSaveFailureDoesNotReserveGIFQuotaOrChangeSelection() async throws {
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
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store, engine: engine)
        defer { model.stop() }
        model.refreshPlayback(force: false)
        try FileManager.default.removeItem(at: store.stateURL)
        try FileManager.default.createDirectory(at: store.stateURL, withIntermediateDirectories: false)
        model.apply(item, to: displayID)
        try await waitForAdmission(model, on: displayID)
        XCTAssertTrue(model.errorMessage?.contains("salvar") == true)
        XCTAssertEqual(model.state, state)
        XCTAssertEqual(engine.gifBudget.totalBytes, 0)
    }

    func testNativeFitPreferenceDoesNotChangeOfficialWebEmbedState() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let screen = NSScreen.screens.first, let displayID = Display.identify(screen) else {
            throw XCTSkip("É necessário um display para validar a seleção.")
        }
        let store = LibraryStore(rootURL: directory.appendingPathComponent("Library"))
        let item = try Wallpaper.web("https://youtu.be/M7lc1UVf-VE")
        let initial = LibraryState(wallpapers: [item], assignments: [displayID: item.id],
                                   settings: .init(isManuallyPaused: true))
        try store.save(initial)
        let bytes = try Data(contentsOf: store.stateURL)
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store)
        defer { model.stop() }
        model.refreshPlayback(force: false)
        model.setMediaFit(.fill, on: displayID)
        XCTAssertEqual(model.state, initial)
        XCTAssertEqual(try Data(contentsOf: store.stateURL), bytes)
    }

    func testMirrorApplyClearAndSwitchBackRestoreIndependentState() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(rootURL: directory)
        let first = try Wallpaper.remote("https://example.com/first.mp4")
        let second = try Wallpaper.remote("https://example.com/second.mp4")
        var initial = LibraryState(wallpapers: [first, second], assignments: ["one": first.id, "two": second.id])
        initial.setMediaFit(.fill, for: first.id, on: "one")
        try store.save(initial)
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store, engine: DesktopCoordinator(targets: { [] }),
                                 connectedDisplays: { [Display(id: "one", name: "One"), Display(id: "two", name: "Two")] })
        defer { model.stop() }
        model.refreshPlayback(force: false)
        model.setDisplayMode(.mirrored, sourceDisplayID: "one")
        XCTAssertEqual(model.activeWallpaperID(on: "two"), first.id)
        XCTAssertEqual(model.mediaFit(on: "two"), .fill)
        model.apply(second, to: "two")
        model.setMediaFit(.fit, on: "two")
        XCTAssertEqual(model.activeWallpaperID(on: "one"), second.id)
        XCTAssertEqual(model.mediaFit(on: "one"), .fit)
        XCTAssertEqual(model.state.assignments, initial.assignments)
        XCTAssertEqual(model.state.mediaFits, initial.mediaFits)
        XCTAssertEqual(try store.load(), model.state)
        model.clear(displayID: "one")
        XCTAssertNil(model.activeWallpaperID(on: "two"))
        model.setDisplayMode(.independent, sourceDisplayID: "two")
        XCTAssertEqual(model.activeWallpaperID(on: "one"), first.id)
        XCTAssertEqual(model.activeWallpaperID(on: "two"), second.id)
        XCTAssertEqual(model.mediaFit(on: "one"), .fill)
        XCTAssertNil(model.errorMessage)
    }

    func testPanoramaInheritsNativeVideoAndRestoresIndependentAssignments() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(rootURL: directory)
        let photo = Wallpaper(title: "Photo", kind: .image, source: .local(filename: "photo.png"))
        let video = try Wallpaper.remote("https://example.com/first.mp4")
        let initial = LibraryState(wallpapers: [photo, video], assignments: ["one": video.id, "two": photo.id])
        try store.save(initial)
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store, engine: DesktopCoordinator(targets: { [] }),
                                 connectedDisplays: { [Display(id: "one", name: "One"), Display(id: "two", name: "Two")] })
        defer { model.stop() }
        model.refreshPlayback(force: false)
        model.setDisplayMode(.spanned, sourceDisplayID: "one")
        XCTAssertEqual(model.state.displayMode, .spanned)
        XCTAssertEqual(model.state.mirroredWallpaperID,video.id)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.state.assignments, initial.assignments)
        XCTAssertEqual(try store.load(), model.state)
        model.setDisplayMode(.independent, sourceDisplayID: "two")
        model.setDisplayMode(.spanned, sourceDisplayID: "two")
        XCTAssertEqual(model.activeWallpaperID(on: "one"), photo.id)
        model.setMediaFit(.stretch, on: "one")
        XCTAssertEqual(model.mediaFit(on: "two"), .stretch)
        model.apply(video, to: "two")
        XCTAssertEqual(model.activeWallpaperID(on: "one"), video.id)
        XCTAssertEqual(try store.load(),model.state)
        model.clear(displayID: "one")
        XCTAssertNil(model.activeWallpaperID(on: "two"))
        model.setDisplayMode(.independent, sourceDisplayID: "one")
        XCTAssertEqual(model.state.assignments, initial.assignments)
        XCTAssertEqual(model.activeWallpaperID(on: "one"), video.id)
        XCTAssertEqual(model.activeWallpaperID(on: "two"), photo.id)
    }

    func testPanoramaStartsEmptyFromOfficialWebWithoutDiscardingIndependentSelection() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let items = [try Wallpaper.web("https://youtu.be/M7lc1UVf-VE")]
        for item in items {
            let store = LibraryStore(rootURL: directory.appendingPathComponent(item.id.uuidString))
            let initial = LibraryState(wallpapers: [item], assignments: ["one": item.id])
            try store.save(initial)
            let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(),
                store: store, engine: DesktopCoordinator(targets: { [] }),
                connectedDisplays: { [Display(id: "one", name: "One")] })
            defer { model.stop() }
            model.refreshPlayback(force: false)
            model.setDisplayMode(.spanned, sourceDisplayID: "one")
            XCTAssertEqual(model.state.displayMode, .spanned)
            XCTAssertNil(model.state.mirroredWallpaperID)
            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(try store.load(), model.state)
            model.setDisplayMode(.independent, sourceDisplayID: "one")
            try await waitForAdmission(model, on: "one")
            XCTAssertEqual(model.activeWallpaperID(on: "one"), item.id)
        }
    }

    func testApplyAvailabilityDistinguishesPanoramaMediaAndDisconnectedTargetsUsingCurrentRecord() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = Wallpaper(title: "Photo", kind: .image, source: .local(filename: "photo.png"))
        let gif = Wallpaper(title: "GIF", kind: .gif, source: .local(filename: "animation.gif"))
        let video = try Wallpaper.remote("https://example.com/video.mp4")
        let web = try Wallpaper.web("https://youtu.be/M7lc1UVf-VE")
        let items = [photo, gif, video, web]
        let store = LibraryStore(rootURL: directory)
        try store.save(LibraryState(wallpapers: items))
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(),
            store: store, engine: DesktopCoordinator(targets: { [] }),
            connectedDisplays: { [Display(id: "one", name: "One")] })
        defer { model.stop() }
        model.refreshPlayback(force: false)
        for mode in [DisplayMode.independent, .mirrored, .spanned] {
            model.setDisplayMode(mode, sourceDisplayID: "one")
            for item in items {
                XCTAssertEqual(model.applicationRestriction(for: item, on: "one") == nil,
                    mode != .spanned || item.id != web.id)
                XCTAssertNotNil(model.applicationRestriction(for: item, on: "missing"))
            }
        }
        var stalePhoto = photo
        stalePhoto.kind = .video
        stalePhoto.source = video.source
        XCTAssertNil(model.applicationRestriction(for: stalePhoto, on: "one"), "Current stored record controls compatibility")
        let missing = Wallpaper(title: "Missing", kind: .image, source: photo.source)
        XCTAssertNotNil(model.applicationRestriction(for: missing, on: "one"))
        XCTAssertNil(model.errorMessage, "Availability must not mutate state or emit an alert")
    }

    func testMirrorSeedUsesSelectedEmptyDisplayRatherThanOtherAssignment() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(rootURL: directory)
        let item = try Wallpaper.remote("https://example.com/first.mp4")
        try store.save(LibraryState(wallpapers: [item], assignments: ["one": item.id]))
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store, engine: DesktopCoordinator(targets: { [] }),
                                 connectedDisplays: { [Display(id: "one", name: "One"), Display(id: "two", name: "Two")] })
        defer { model.stop() }
        model.refreshPlayback(force: false)
        model.setDisplayMode(.mirrored, sourceDisplayID: "two")
        XCTAssertNil(model.state.mirroredWallpaperID)
        XCTAssertNil(model.activeWallpaperID(on: "one"))
        XCTAssertEqual(model.state.assignments, ["one": item.id])
    }

    func testAudioSelectionRejectsDisconnectedAndSurvivesUnplugWithoutFallback() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(rootURL: directory)
        let connected = TestDisplays([Display(id: "one", name: "One"), Display(id: "two", name: "Two")])
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store, engine: DesktopCoordinator(targets: { [] }), connectedDisplays: { connected.values })
        defer { model.stop() }
        model.refreshPlayback(force: false)
        XCTAssertNil(model.state.settings.audioDisplayID)
        model.setAudioDisplayID("unknown")
        XCTAssertNil(model.state.settings.audioDisplayID)
        model.setAudioDisplayID("two")
        XCTAssertEqual(model.state.settings.audioDisplayID, "two")
        connected.values.removeLast()
        model.refreshPlayback(force: false)
        XCTAssertEqual(model.state.settings.audioDisplayID, "two")
        model.setAudioDisplayID("unknown")
        XCTAssertEqual(model.state.settings.audioDisplayID, "two")
        let restored = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store, engine: DesktopCoordinator(targets: { [] }), connectedDisplays: { connected.values })
        defer { restored.stop() }
        restored.refreshPlayback(force: false)
        XCTAssertEqual(restored.state.settings.audioDisplayID, "two")
        connected.values.append(Display(id: "two", name: "Two"))
        restored.refreshPlayback(force: false)
        XCTAssertEqual(restored.state.settings.audioDisplayID, "two")
        restored.setAudioDisplayID(nil)
        XCTAssertNil(try store.load().settings.audioDisplayID)
    }

    func testModeSwitchPreflightFailurePreservesLibraryBytesAndIndependentState() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let screen = NSScreen.screens.first, let displayID = Display.identify(screen) else {
            throw XCTSkip("A connected screen is required for renderer preflight.")
        }
        let store = LibraryStore(rootURL: directory)
        // A restored assignment can reference media that disappeared on disk.
        let missing = Wallpaper(title: "Missing GIF", kind: .gif, source: .local(filename: "missing.gif"))
        let initial = LibraryState(wallpapers: [missing], assignments: [displayID: missing.id])
        try store.save(initial)
        let bytes = try Data(contentsOf: store.stateURL)
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store)
        defer { model.stop() }
        model.refreshPlayback(force: false)
        model.setDisplayMode(.mirrored, sourceDisplayID: displayID)
        try await waitForAdmission(model, on: displayID)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.state, initial)
        XCTAssertEqual(try Data(contentsOf: store.stateURL), bytes)
    }

    func testQuickSoundActionUsesRealOwnerRejectsSilentTargetsAndPreservesLevels() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(rootURL: directory)
        let photo = Wallpaper(title: "Foto", kind: .image, source: .local(filename: "photo.png"))
        let video = try Wallpaper.remote("https://example.invalid/video.mp4")
        var state = LibraryState(wallpapers: [photo, video], assignments: ["photo": photo.id, "video": video.id],
                                 settings: .init(isManuallyPaused: true, audioVolume: 0.37))
        state.setAudioGain(0.4, for: video.id)
        try store.save(state)
        let connected = TestDisplays([Display(id: "photo", name: "Foto"), Display(id: "video", name: "Vídeo")])
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(),
            store: store, engine: DesktopCoordinator(targets: { [] }), connectedDisplays: { connected.values })
        defer { model.stop() }
        model.refreshPlayback(force: false)
        model.toggleAudioPermission(preferredDisplayID: "photo")
        model.toggleAudioPermission(preferredDisplayID: "disconnected")
        XCTAssertNil(model.state.settings.audioDisplayID)
        model.toggleAudioPermission() // The menu skips the first, silent display.
        XCTAssertEqual(model.state.settings.audioDisplayID, "video")
        model.toggleAudioPermission(preferredDisplayID: "photo") // Global mute clears the real owner.
        XCTAssertNil(model.state.settings.audioDisplayID)
        model.toggleAudioPermission(preferredDisplayID: "video")
        XCTAssertEqual(model.state.settings.audioDisplayID, "video")
        connected.values.removeLast()
        model.refreshPlayback(force: false)
        XCTAssertEqual(model.state.settings.audioDisplayID, "video")
        model.toggleAudioPermission(preferredDisplayID: "photo") // Disconnected owners can also be cleared.
        XCTAssertNil(model.state.settings.audioDisplayID)
        model.toggleAudioPermission()
        XCTAssertNil(model.state.settings.audioDisplayID)
        XCTAssertEqual(model.state.settings.audioVolume, 0.37)
        XCTAssertEqual(model.state.audioGain(for: video.id), 0.4)
        XCTAssertTrue(model.state.settings.isManuallyPaused)
        XCTAssertEqual(try store.load(), model.state)
    }

    func testQuickSoundSaveFailureDoesNotArmAudioOrChangeVolume() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(rootURL: directory)
        let video = try Wallpaper.remote("https://example.invalid/video.mp4")
        let state = LibraryState(wallpapers: [video], assignments: ["video": video.id], settings: .init(audioVolume: 0.42))
        try store.save(state)
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(),
            store: store, engine: DesktopCoordinator(targets: { [] }), connectedDisplays: { [Display(id: "video", name: "Vídeo")] })
        defer { model.stop() }
        model.refreshPlayback(force: false)
        try FileManager.default.removeItem(at: store.stateURL)
        try FileManager.default.createDirectory(at: store.stateURL, withIntermediateDirectories: false)
        model.toggleAudioPermission(preferredDisplayID: "video")
        XCTAssertNil(model.state.settings.audioDisplayID)
        XCTAssertEqual(model.state.settings.audioVolume, 0.42)
        XCTAssertNotNil(model.errorMessage)
    }

    func testAudioSaveFailurePreservesSelection() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(rootURL: directory)
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store, engine: DesktopCoordinator(targets: { [] }),
                                 connectedDisplays: { [Display(id: "one", name: "One")] })
        defer { model.stop() }
        model.refreshPlayback(force: false)
        try FileManager.default.createDirectory(at: store.stateURL, withIntermediateDirectories: false)
        model.setAudioDisplayID("one")
        XCTAssertNil(model.state.settings.audioDisplayID)
        XCTAssertTrue(model.errorMessage?.contains("salvar") == true)
    }

    func testAudioVolumePersistsAndRejectsInvalidValuesAndFailedSave() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(rootURL: directory)
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store, engine: DesktopCoordinator(targets: { [] }))
        defer { model.stop() }
        model.setAudioVolume(0.35)
        XCTAssertEqual(model.state.settings.audioVolume, 0.35)
        XCTAssertEqual(try store.load().settings.audioVolume, 0.35)
        let bytes = try Data(contentsOf: store.stateURL)
        for invalid in [Double.nan, .infinity, -1, 2] { model.setAudioVolume(invalid) }
        XCTAssertEqual(try Data(contentsOf: store.stateURL), bytes)
        try FileManager.default.removeItem(at: store.stateURL)
        try FileManager.default.createDirectory(at: store.stateURL, withIntermediateDirectories: false)
        model.setAudioVolume(0.7)
        XCTAssertEqual(model.state.settings.audioVolume, 0.35)
        XCTAssertNotNil(model.errorMessage)
    }

    func testHLSPreferencePersistsAndFailedSavePreservesPreviousSelection() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(rootURL: directory.appendingPathComponent("Library", isDirectory: true))
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store, connectedDisplays: { [] })
        defer { model.stop() }
        model.setHLSResolution(.fullHD1080)
        XCTAssertEqual(model.state.settings.hlsResolution, .fullHD1080)
        XCTAssertEqual(try store.load().settings.hlsResolution, .fullHD1080)
        let bytes = try Data(contentsOf: store.stateURL)
        model.setHLSResolution(.fullHD1080)
        XCTAssertEqual(try Data(contentsOf: store.stateURL), bytes)
        try FileManager.default.removeItem(at: store.stateURL)
        try FileManager.default.createDirectory(at: store.stateURL, withIntermediateDirectories: false)
        model.setHLSResolution(.hd720)
        XCTAssertEqual(model.state.settings.hlsResolution, .fullHD1080)
        XCTAssertNotNil(model.errorMessage)
    }

    func testOptionalLibraryViewSnapshotUsesOnlyTemporaryFixtures() async throws {
        guard let path = ProcessInfo.processInfo.environment["WALLMOTION_SNAPSHOT_PATH"], !path.isEmpty else {
            throw XCTSkip("Defina WALLMOTION_SNAPSHOT_PATH para exportar o snapshot de QA.")
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(rootURL: directory.appendingPathComponent("Library", isDirectory: true))
        let environment = ProcessInfo.processInfo.environment
        let syntheticCount = environment["WALLMOTION_SNAPSHOT_DISPLAY_COUNT"].flatMap(Int.init)
        if let syntheticCount, !(0...20).contains(syntheticCount) { throw XCTSkip("Synthetic display count must be 0...20") }
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store, engine: DesktopCoordinator(targets: { [] }), connectedDisplays: {
            if let syntheticCount {
                return (0..<syntheticCount).map { Display(id: "fixture-\($0)", name: "Monitor de teste \($0 + 1)") }
            }
            return [Display(id: "fixture-left", name: "Monitor principal"), Display(id: "fixture-right", name: "Monitor externo")]
        })
        defer { model.stop() }
        let photo = directory.appendingPathComponent("Montanhas ao amanhecer.png")
        _ = try writePhoto(to: photo)
        await model.importFiles([photo])
        XCTAssertTrue(model.addURL("https://media.example.com/Oceano.mp4"))
        XCTAssertTrue(model.addURL("https://media.example.com/Cidade-noturna.m3u8"))
        model.refreshPlayback(force: false)

        if let display = model.displays.first, environment["WALLMOTION_SNAPSHOT_NO_ASSIGNMENT"] != "1" {
            let index = environment["WALLMOTION_SNAPSHOT_APPLY_INDEX"].flatMap(Int.init) ?? 0
            guard model.state.wallpapers.indices.contains(index) else { throw XCTSkip("Invalid fixture index") }
            model.apply(model.state.wallpapers[index], to: display.id)
            model.setMediaFit(.fill, on: display.id)
            if environment["WALLMOTION_SNAPSHOT_AUDIO"] == "1" {
                model.setAudioDisplayID(display.id)
            }
        }
        let compact = environment["WALLMOTION_SNAPSHOT_COMPACT"] == "1"
        if environment["WALLMOTION_SNAPSHOT_MIRRORED"] == "1", let display = model.displays.first {
            model.setDisplayMode(.mirrored, sourceDisplayID: display.id)
        }
        if environment["WALLMOTION_SNAPSHOT_PANORAMA"] == "1", let display = model.displays.first {
            model.setDisplayMode(.spanned, sourceDisplayID: display.id)
        }
        let bounds = NSRect(x: 0, y: 0, width: compact ? 820 : 1120, height: compact ? 560 : 760)
        let appearance: NSAppearance.Name = environment["WALLMOTION_SNAPSHOT_LIGHT"] == "1" ? .aqua : .darkAqua
        let query = LibraryQuery(text: environment["WALLMOTION_SNAPSHOT_SEARCH"] ?? "",
            filter: LibraryMediaFilter(rawValue: environment["WALLMOTION_SNAPSHOT_FILTER"] ?? "") ?? .all,
            sort: LibrarySortOrder(rawValue: environment["WALLMOTION_SNAPSHOT_SORT"] ?? "") ?? .recent)
        let hosting = NSHostingView(rootView: LibraryView(model: model, initialQuery: query, initialSceneControls: environment["WALLMOTION_SNAPSHOT_SCENE_CONTROLS"] == "1"))
        hosting.appearance = NSAppearance(named: appearance)
        hosting.frame = bounds
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        let compositorCapture = environment["WALLMOTION_COMPOSITOR_SNAPSHOT"] == "1"
        window.setFrameOrigin(compositorCapture ? NSPoint(x: 80, y: 80) : NSPoint(x: -10000, y: -10000))
        if compositorCapture { window.makeKeyAndOrderFront(nil) } else { window.orderBack(nil) }
        defer { window.orderOut(nil); window.close() }
        // Let fixture thumbnail tasks start; this delay alone is not a pass condition.
        try await Task.sleep(for: .milliseconds(250))
        if environment["WALLMOTION_SNAPSHOT_SIDEBAR_BOTTOM"] == "1" {
            hosting.layoutSubtreeIfNeeded()
            func scrollViews(in view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
            }
            let sidebar = try XCTUnwrap(scrollViews(in: hosting).first {
                $0.bounds.width < 320 && ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 1
            })
            let document = try XCTUnwrap(sidebar.documentView)
            let before = sidebar.contentView.bounds.origin
            let bottom = document.isFlipped ? max(document.bounds.minY, document.bounds.maxY - sidebar.contentView.bounds.height) : document.bounds.minY
            sidebar.contentView.scroll(to: NSPoint(x: before.x, y: bottom))
            sidebar.reflectScrolledClipView(sidebar.contentView)
            XCTAssertNotEqual(sidebar.contentView.bounds.origin, before, "Overflowing sidebar must reach its lower controls.")
            try await Task.sleep(for: .milliseconds(100))
        }
        let bitmap = try await LibrarySnapshotCapture.capture(hosting)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let destination = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: destination, options: .atomic)
        if compositorCapture {
            guard #available(macOS 14.4, *) else { throw XCTSkip("Own-window compositor capture requires macOS 14.4") }
            // Current-process-only enumeration needs no TCC grant and never captures another app.
            let content = try await SCShareableContent.currentProcess
            let ownWindow = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
            let filter = SCContentFilter(desktopIndependentWindow: ownWindow)
            let scale = CGFloat(filter.pointPixelScale)
            let configuration = SCStreamConfiguration()
            configuration.width = Int((filter.contentRect.width * scale).rounded())
            configuration.height = Int((filter.contentRect.height * scale).rounded())
            configuration.showsCursor = false
            configuration.captureResolution = .best
            configuration.ignoreShadowsSingleWindow = true
            configuration.colorSpaceName = CGColorSpace.sRGB
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            print("compositor_qa window=\(window.frame) backing_scale=\(window.backingScaleFactor) filter_rect=\(filter.contentRect) filter_scale=\(scale) output=\(image.width)x\(image.height)")
            let composed = NSBitmapImageRep(cgImage: image)
            XCTAssertTrue(LibrarySnapshotCapture.hasContent(composed))
            let composedURL = destination.deletingPathExtension().appendingPathExtension("compositor.png")
            try XCTUnwrap(composed.representation(using: .png, properties: [:])).write(to: composedURL, options: .atomic)
        }
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
    }
}
