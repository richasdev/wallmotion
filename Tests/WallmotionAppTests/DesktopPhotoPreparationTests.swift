import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
import WallmotionCore
@testable import Wallmotion

@MainActor
final class DesktopPhotoPreparationTests: XCTestCase {
    private final class Windows {
        var values: [NSWindow] = []
        func visible(_ window: NSWindow) -> Bool {
            if !values.contains(where: { $0 === window }) { values.append(window) }
            return true
        }
    }

    private func writePhoto(_ url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func temporaryStore() throws -> (URL, LibraryStore, Wallpaper, Wallpaper) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionAsyncPhotos-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let firstURL = root.appendingPathComponent("first.png")
        let nextURL = root.appendingPathComponent("next.png")
        try writePhoto(firstURL)
        try writePhoto(nextURL)
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        return (root, store, try store.importFile(at: firstURL), try store.importFile(at: nextURL))
    }

    func testPendingPhotoPreservesWindowAndUsesLatestPauseWithoutMainThreadDecode() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let (root, store, first, next) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let nextURL = try store.resolvedURL(for: next)
        let gate = PhotoTestGate()
        let entered = expectation(description: "background preparation started")
        let windows = Windows()
        let engine = DesktopCoordinator(targets: { [DesktopTarget(id: "left", screen: screen)] },
            isWindowVisible: { windows.visible($0) }, photoDecoder: { request in
                if request.url == nextURL { entered.fulfill(); await gate.wait() }
                return try await PhotoDecodeWorker.shared.decode(request)
            })
        defer { engine.stop() }
        var state = LibraryState(wallpapers: [first, next], assignments: ["left": first.id])
        engine.rebuild(state: state, store: store, paused: false) { _, error in XCTFail(error) }
        let original = try XCTUnwrap(windows.values.first)
        state.assignments["left"] = next.id
        engine.scheduleRebuild(state: state, store: store, paused: false) { _, error in XCTFail(error) }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(original.isVisible, "Keep old wallpaper while decoding")
        XCTAssertEqual(windows.values.count, 1)
        engine.setPaused(true)
        await gate.release()
        let deadline = ContinuousClock.now + .seconds(3)
        while windows.values.count < 2 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(windows.values.count, 2)
        XCTAssertFalse(original.isVisible)
        let replacement = try XCTUnwrap(windows.values.last?.contentView as? ImageSurface)
        XCTAssertFalse(replacement.imageView.animates, "Late completion must preserve current system/manual pause")
    }

    func testClearCancelsPendingPhotoAndDoesNotResurrectWindow() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let (root, store, first, next) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = PhotoTestGate()
        let entered = expectation(description: "decode entered")
        let released = expectation(description: "uncooperative codec returned")
        let nextURL = try store.resolvedURL(for: next)
        let windows = Windows()
        let engine = DesktopCoordinator(targets: { [DesktopTarget(id: "left", screen: screen)] },
            isWindowVisible: { windows.visible($0) }, photoDecoder: { request in
                let result = try await PhotoDecodeWorker.shared.decode(request)
                if request.url == nextURL { entered.fulfill(); await gate.wait(); released.fulfill() }
                return result
            })
        defer { engine.stop() }
        var state = LibraryState(wallpapers: [first, next], assignments: ["left": first.id])
        engine.rebuild(state: state, store: store, paused: true) { _, error in XCTFail(error) }
        let original = try XCTUnwrap(windows.values.first)
        state.assignments["left"] = next.id
        engine.scheduleRebuild(state: state, store: store, paused: true) { _, error in XCTFail(error) }
        await fulfillment(of: [entered], timeout: 2)
        state.assignments = [:]
        engine.scheduleRebuild(state: state, store: store, paused: true) { _, error in XCTFail(error) }
        XCTAssertFalse(original.isVisible)
        await gate.release()
        await fulfillment(of: [released], timeout: 2)
        // Yield to the cancelled task after the injected codec ignores cancellation.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(windows.values.count, 1)
        XCTAssertEqual(engine.gifBudget.totalBytes, 0)
    }

    func testDecodeFailurePreservesPreviousRenderer() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let (root, store, first, next) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let failed = expectation(description: "decode failed")
        let windows = Windows()
        let engine = DesktopCoordinator(targets: { [DesktopTarget(id: "left", screen: screen)] },
            isWindowVisible: { windows.visible($0) }, photoDecoder: { _ in throw PhotoDecodingError.unreadable })
        defer { engine.stop() }
        var state = LibraryState(wallpapers: [first, next], assignments: ["left": first.id])
        engine.rebuild(state: state, store: store, paused: true) { _, error in XCTFail(error) }
        let original = try XCTUnwrap(windows.values.first)
        state.assignments["left"] = next.id
        engine.scheduleRebuild(state: state, store: store, paused: true) { id, _ in
            XCTAssertEqual(id, "left")
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertTrue(original.isVisible)
        XCTAssertEqual(windows.values.count, 1)
        XCTAssertEqual(engine.gifBudget.totalBytes, 0)
    }
}
