import AppKit
import SwiftUI
import XCTest
import WallmotionCore
@testable import Wallmotion

@MainActor
final class RenameSheetLifecycleTests: XCTestCase {
    func testPresentedRenameSheetDismissesWhenItsItemIsRemoved() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionRenameLifecycle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try Wallpaper.remote("https://example.com/video.mp4")
        let store = LibraryStore(rootURL: root)
        try store.save(LibraryState(wallpapers: [item]))
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(),
            store: store, engine: DesktopCoordinator(targets: { [] }), connectedDisplays: { [] })
        defer { model.stop() }
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let hosting = NSHostingView(rootView: LibraryView(model: model, initialRename: item))
        hosting.frame = bounds
        let window = NSWindow(contentRect: bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        defer {
            for sheet in window.sheets { window.endSheet(sheet); sheet.orderOut(nil) }
            window.orderOut(nil)
            window.close()
        }
        let presentationDeadline = ContinuousClock.now + .seconds(3)
        while window.sheets.isEmpty, ContinuousClock.now < presentationDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(window.sheets.count, 1, "Fixture must present the real SwiftUI rename sheet")
        guard !window.sheets.isEmpty else { return }
        model.remove(item)
        let savedAfterRemoval = try Data(contentsOf: store.stateURL)
        let dismissalDeadline = ContinuousClock.now + .seconds(3)
        while !window.sheets.isEmpty, ContinuousClock.now < dismissalDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(window.sheets.isEmpty)
        XCTAssertEqual(try Data(contentsOf: store.stateURL), savedAfterRemoval)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.state.wallpapers.isEmpty)
    }
}
