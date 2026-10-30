import AppKit
import SwiftUI
import XCTest
import WallmotionCore
@testable import Wallmotion

@MainActor
final class ApplicationSessionTests: XCTestCase {
    private func root() throws -> URL {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testBusyNeverBuildsModelAndRetryAcquiresBeforePublicationAndModel() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let holder = try XCTUnwrap(try LibraryProcessLock.acquire(in: root))
        defer { holder.release() }
        var order: [String] = []
        let session = ApplicationSession(store: store, publish: { lease in
            order.append("publish")
            XCTAssertNil(try LibraryProcessLock.acquire(in: root))
            try lease.publishIdentity(.init(processID: 123, bundleIdentifier: "dev.test.fixture", launchTime: 42))
        }, makeModel: {
            order.append("model")
            return LibraryModel(thermalState: { .nominal }, store: store, connectedDisplays: { [] })
        })
        defer { session.stop() }
        session.prepare()
        session.finishLaunching()
        XCTAssertEqual(session.phase, .busy)
        XCTAssertNil(session.model)
        XCTAssertTrue(order.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.stateURL.path))
        holder.release()
        session.prepare()
        XCTAssertEqual(session.phase, .primary)
        XCTAssertEqual(order, ["publish", "model"])
        session.prepare()
        XCTAssertEqual(order.count, 2)
        session.stop()
        try withExtendedLifetime(session) {
            let other = try LibraryProcessLock.acquire(in: root)
            XCTAssertNil(other)
        } // Retain ownership until session/process ends.
    }

    func testAcquisitionFailureNeverPublishesOrConstructsModel() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        let store = LibraryStore(rootURL: root)
        let session = ApplicationSession(store: store, acquire: { throw NSError(domain: "PRIVATE_TOKEN", code: 1) }, publish: { _ in calls += 1 }, makeModel: {
            calls += 1
            return LibraryModel(thermalState: { .nominal }, store: store, connectedDisplays: { [] })
        })
        session.prepare()
        XCTAssertEqual(session.phase, .failed)
        XCTAssertNil(session.model)
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(session.errorMessage?.contains("PRIVATE_TOKEN") == true)
    }

    func testPublicationFailureReleasesLeaseBeforeAnyModelWork() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        var modelCount = 0
        let session = ApplicationSession(store: store, publish: { _ in throw NSError(domain: "PRIVATE_TOKEN", code: 2) }, makeModel: {
            modelCount += 1
            return LibraryModel(thermalState: { .nominal }, store: store, connectedDisplays: { [] })
        })
        session.prepare()
        XCTAssertEqual(session.phase, .failed)
        XCTAssertNil(session.model)
        XCTAssertEqual(modelCount, 0)
        XCTAssertFalse(session.errorMessage?.contains("PRIVATE_TOKEN") == true)
        let acquired = try XCTUnwrap(try LibraryProcessLock.acquire(in: root))
        acquired.release()
    }
    func testOptionalAdmissionRootUpdatesToLibrarySnapshot() async throws {
        guard let path = ProcessInfo.processInfo.environment["WALLMOTION_STARTUP_SNAPSHOT_PATH"] else { throw XCTSkip("Opt-in admitted root snapshot") }
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        try store.save(LibraryState(wallpapers: [try Wallpaper.remote("https://example.com/Admission.mp4")]))
        let session = ApplicationSession(store: store, publish: { lease in
            try lease.publishIdentity(.init(processID: 123, bundleIdentifier: "dev.test.fixture", launchTime: 42))
        }, makeModel: { LibraryModel(thermalState: { .nominal }, store: store, connectedDisplays: { [] }) })
        defer { session.stop() }
        let events = LaunchEventRouter(isPrimary: { session.model != nil }, isBusy: { session.phase == .busy }, importURLs: { _ in }, activateOwner: {}, forward: { _ in }, terminate: {})
        let hosting = NSHostingView(rootView: LibraryWindowContent(session: session, events: events, onRetry: {}).frame(minWidth: 820, minHeight: 560))
        let bounds = NSRect(x: 0, y: 0, width: 820, height: 560)
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = bounds
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(50))
        session.prepare()
        session.finishLaunching()
        try await Task.sleep(for: .milliseconds(250))
        let bitmap = try await LibrarySnapshotCapture.capture(hosting)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path), options: .atomic)
        XCTAssertEqual(session.phase, .primary)
    }
}
