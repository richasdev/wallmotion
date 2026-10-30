import AppKit
import SwiftUI
import XCTest
@testable import Wallmotion

final class PhotoQualityInfoTests: XCTestCase {
    func testOrientedSourceAndPreparedDimensionsRemainDistinctWithoutRetainingPixels() throws {
        let id = UUID()
        let info = try XCTUnwrap(PhotoQualityInfo(wallpaperID: id, sourceSize: CGSize(width: 3000, height: 6000),
            bitmapWidth: 500, bitmapHeight: 1000, isPanorama: false))
        XCTAssertEqual(info.sourceWidth, 3000)
        XCTAssertEqual(info.sourceHeight, 6000)
        XCTAssertEqual(info.bitmapWidth, 500)
        XCTAssertEqual(info.bitmapHeight, 1000)
        XCTAssertTrue(info.isReduced)
    }

    func testInvalidSourceDimensionsCannotTrapIntegerConversion() {
        for value in [CGFloat.nan, .infinity, -1, 0, 1.5, CGFloat(Int.max)] {
            XCTAssertNil(PhotoQualityInfo(wallpaperID: UUID(), sourceSize: CGSize(width: value, height: 10),
                bitmapWidth: 1, bitmapHeight: 1, isPanorama: false))
        }
        XCTAssertNil(PhotoQualityInfo(wallpaperID: UUID(), sourceSize: CGSize(width: 10, height: 10),
            bitmapWidth: 0, bitmapHeight: 1, isPanorama: false))
    }
    @MainActor
    func testOptionalPhotoQualitySnapshot() async throws {
        guard let path = ProcessInfo.processInfo.environment["WALLMOTION_PHOTO_QUALITY_SNAPSHOT"], !path.isEmpty else {
            throw XCTSkip("Set WALLMOTION_PHOTO_QUALITY_SNAPSHOT for component QA")
        }
        _ = NSApplication.shared
        let quality = try XCTUnwrap(PhotoQualityInfo(wallpaperID: UUID(), sourceSize: CGSize(width: 12000, height: 6000),
            bitmapWidth: 6000, bitmapHeight: 3000, isPanorama: true))
        let hosting = NSHostingView(rootView: PhotoQualityDetails(quality: quality)
            .padding(20).frame(width: 360, alignment: .leading).background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = CGRect(x: 0, y: 0, width: 360, height: 170)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        let bitmap = try await LibrarySnapshotCapture.capture(hosting)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

}
