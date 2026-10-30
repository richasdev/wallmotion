import AppKit
import SwiftUI
import XCTest
import WallmotionCore
@testable import Wallmotion

final class LibrarySearchDraftTests: XCTestCase {
    func testByteBoundariesAndInitialRejectionDoNotRetainPartialQuery() {
        XCTAssertTrue(LibrarySearchDraft.accepts(String(repeating: "a", count: 4096)))
        XCTAssertFalse(LibrarySearchDraft.accepts(String(repeating: "a", count: 4097)))
        XCTAssertTrue(LibrarySearchDraft.accepts(String(repeating: "🌅", count: 1024)))
        XCTAssertFalse(LibrarySearchDraft.accepts(String(repeating: "🌅", count: 1025)))
        let initial = LibrarySearchDraft(text: String(repeating: "a", count: 4097))
        XCTAssertTrue(initial.text.isEmpty)
        XCTAssertNotNil(initial.notice)
    }

    func testRejectedPastePreservesQueryAndIdenticalWritebackPreservesNotice() {
        var draft = LibrarySearchDraft(text: "montanhas")
        XCTAssertTrue(draft.replace(with: String(repeating: "x", count: 4097)))
        XCTAssertEqual(draft.text, "montanhas")
        XCTAssertNotNil(draft.notice)
        XCTAssertFalse(draft.replace(with: "montanhas"))
        XCTAssertNotNil(draft.notice)
        XCTAssertTrue(draft.replace(with: "oceano"))
        XCTAssertEqual(draft.text, "oceano")
        XCTAssertNil(draft.notice)
    }

    func testCanonicalEquivalenceDoesNotHideAByteEditOrOversizedInput() {
        var draft = LibrarySearchDraft(text: "caf\u{00E9}")
        let incoming = "cafe\u{0301}"
        XCTAssertTrue(draft.replace(with: incoming))
        XCTAssertTrue(draft.text.utf8.elementsEqual(incoming.utf8))
        let original = String(repeating: "\u{00E9}", count: 1500)
        let oversized = String(repeating: "e\u{0301}", count: 1500)
        XCTAssertEqual(original, oversized)
        draft = LibrarySearchDraft(text: original)
        draft.replace(with: oversized)
        XCTAssertTrue(draft.text.utf8.elementsEqual(original.utf8))
        XCTAssertNotNil(draft.notice)
    }

    func testExplicitClearResetsNoticeEvenForRejectedInitiallyEmptyQuery() {
        var draft = LibrarySearchDraft(text: String(repeating: "x", count: 4097))
        XCTAssertFalse(draft.replace(with: ""))
        XCTAssertNotNil(draft.notice)
        draft.clear()
        XCTAssertTrue(draft.text.isEmpty)
        XCTAssertNil(draft.notice)
    }

    @MainActor
    func testOptionalNoticeSnapshotsIncludeEmptyLibraryAndNoMatchingItems() async throws {
        guard let path = ProcessInfo.processInfo.environment["WALLMOTION_SEARCH_SNAPSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set WALLMOTION_SEARCH_SNAPSHOT_DIR for bounded-search component QA")
        }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionSearchQA-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        for empty in [true, false] {
            let store = LibraryStore(rootURL: root.appendingPathComponent(empty ? "empty" : "no-match"))
            let items = empty ? [] : [try Wallpaper.remote("https://example.com/video.mp4")]
            try store.save(LibraryState(wallpapers: items))
            let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), store: store,
                engine: DesktopCoordinator(targets: { [] }), connectedDisplays: { [] })
            defer { model.stop() }
            let query = LibraryQuery(text: String(repeating: "x", count: 4097), filter: .photos)
            let hosting = NSHostingView(rootView: LibraryView(model: model, initialQuery: query))
            hosting.appearance = NSAppearance(named: empty ? .darkAqua : .aqua)
            let bounds = NSRect(x: 0, y: 0, width: 1120, height: 760)
            hosting.frame = bounds
            let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            window.orderBack(nil)
            defer { window.orderOut(nil); window.close() }
            let bitmap = try await LibrarySnapshotCapture.capture(hosting)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent(empty ? "empty-dark.png" : "no-match-light.png"), options: .atomic)
        }
    }
}
