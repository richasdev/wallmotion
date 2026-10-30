import AppKit
import SwiftUI
import XCTest
import WallmotionCore
@testable import Wallmotion

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
