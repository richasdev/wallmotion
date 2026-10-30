import AppKit
import SwiftUI
import XCTest
import WallmotionCore
@testable import Wallmotion

@MainActor
final class MediaTitleModelTests: XCTestCase {
    func testRenameChangesOnlyTitleAndRefreshesCatalogSearchAndSort() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let item = try Wallpaper.remote("https://example.com/source.mp4?token=private")
        let second = Wallpaper(title: "B", kind: .image, source: .local(filename: "other.jpg"))
        let before = LibraryState(wallpapers: [item, second], assignments: ["display": item.id], settings: .init(isManuallyPaused: true), mediaFits: ["display": [item.id.uuidString: .fill]], displayMode: .mirrored, mirroredWallpaperID: item.id, mirroredMediaFit: .center)
        try store.save(before)
        let model = LibraryModel(thermalState: { .nominal }, store: store, connectedDisplays: { [] })
        defer { model.stop() }
        let catalog = LibraryCatalogProjection()
        _ = catalog.items(from: model.state.wallpapers, query: .init(text: "Aurora"))
        XCTAssertTrue(model.rename(id: item.id, title: "  Aurora  "))
        var expected = before
        expected.wallpapers[0].title = "Aurora"
        XCTAssertEqual(model.state, expected)
        XCTAssertEqual(try store.load(), expected)
        XCTAssertEqual(catalog.items(from: model.state.wallpapers, query: .init(text: "Aurora")).map(\.id), [item.id])
        XCTAssertEqual(catalog.items(from: model.state.wallpapers, query: .init(sort: .title)).first?.id, item.id)
    }

    func testInvalidMissingAndFailedPublicationPreserveModelAndExistingBytes() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let item = try Wallpaper.remote("https://example.com/source.mp4")
        let before = LibraryState(wallpapers: [item])
        try store.save(before)
        let original = try Data(contentsOf: store.stateURL)
        let model = LibraryModel(thermalState: { .nominal }, store: store, connectedDisplays: { [] })
        defer { model.stop() }
        XCTAssertFalse(model.rename(id: item.id, title: "\n\t"))
        XCTAssertFalse(model.rename(id: UUID(), title: "New name"))
        XCTAssertEqual(model.state, before)
        XCTAssertEqual(try Data(contentsOf: store.stateURL), original)
        let backup = root.appendingPathComponent("preserved.json")
        try FileManager.default.moveItem(at: store.stateURL, to: backup)
        try FileManager.default.createDirectory(at: store.stateURL, withIntermediateDirectories: false)
        XCTAssertFalse(model.rename(id: item.id, title: "New name"))
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.state, before)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertTrue(model.rename(id: item.id, title: "  " + item.title + "  ")) // No-op does not rewrite.
    }

    func testOptionalRenameSheetSnapshot() async throws {
        guard let path = ProcessInfo.processInfo.environment["WALLMOTION_RENAME_SNAPSHOT_PATH"] else { throw XCTSkip("Opt-in rename sheet snapshot") }
        _ = NSApplication.shared
        let bounds = NSRect(x: 0, y: 0, width: 496, height: 300)
        let hosting = NSHostingView(rootView: RenameMediaSheet(title: "Céu de Tóquio", canSave: true, onSave: { _ in nil }, onCancel: {}))
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = bounds
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(250))
        let bitmap = try await LibrarySnapshotCapture.capture(hosting)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
