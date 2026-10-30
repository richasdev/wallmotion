import AppKit
import SwiftUI
import XCTest
@testable import Wallmotion

@MainActor
final class AddURLSheetTests: XCTestCase {
    func testProviderSelectionAndStartFeedbackDoNotAcceptDirectMode() {
        let text = "https://youtu.be/dQw4w9WgXcQ?t=1m30s"
        let direct = URLDraftFeedback(text: text, web: false)
        XCTAssertFalse(direct.isValid)
        XCTAssertEqual(direct.error, "Este link é de um provedor. Selecione YouTube / Vimeo acima.")
        let web = URLDraftFeedback(text: text, web: true)
        XCTAssertTrue(web.isValid)
        XCTAssertEqual(web.summary, "YouTube · início em 1:30")
        XCTAssertTrue(URLDraftFeedback(text: "https://vimeo.com/19231868", web: true).isValid)
    }

    func testBlankCredentialsAndOversizeInputNeverBecomeReady() {
        let blank = URLDraftFeedback(text: "  ", web: false)
        XCTAssertFalse(blank.isValid)
        XCTAssertNil(blank.error)
        for web in [false, true] {
            XCTAssertFalse(URLDraftFeedback(text: "https://user:secret@example.com/video.mp4", web: web).isValid)
            let oversized = URLDraftFeedback(text: "https://example.com/" + String(repeating: "a", count: 4096), web: web)
            XCTAssertFalse(oversized.isValid)
            XCTAssertNotNil(oversized.error)
        }
    }

    func testFeedbackDoesNotEchoPrivateQueryOrImplyRemoteAvailability() {
        let secret = "private-token-for-test"
        let hls = URLDraftFeedback(text: "https://cdn.example.com/live.m3u8?token=\(secret)", web: false)
        XCTAssertTrue(hls.isValid)
        XCTAssertEqual(hls.summary, "Link HTTPS · transmissão HLS")
        XCTAssertFalse(hls.summary?.contains(secret) ?? true)
        let invalid = URLDraftFeedback(text: "http://example.com/\(secret)", web: false)
        XCTAssertFalse(invalid.isValid)
        XCTAssertFalse(invalid.error?.contains(secret) ?? true)
    }

    func testOptionalURLSheetSnapshots() async throws {
        guard let directory = ProcessInfo.processInfo.environment["WALLMOTION_URL_SNAPSHOT_DIR"] else {
            throw XCTSkip("Opt-in URL sheet snapshots")
        }
        _ = NSApplication.shared
        for (name, text, web, appearance) in [
            ("youtube-dark", "https://youtu.be/dQw4w9WgXcQ?t=90", true, NSAppearance.Name.darkAqua),
            ("invalid-light", "https://youtu.be/dQw4w9WgXcQ", false, NSAppearance.Name.aqua)
        ] {
            let hosting = NSHostingView(rootView: AddURLSheet(text: text, web: web, canAdd: true, onAdd: { _, _ in nil }, onCancel: {}))
            hosting.appearance = NSAppearance(named: appearance)
            let bounds = NSRect(x: 0, y: 0, width: 556, height: 440)
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
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"), options: .atomic)
        }
    }
}
