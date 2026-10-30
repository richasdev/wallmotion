import AppKit
import XCTest
@testable import Wallmotion

@MainActor
final class ThumbnailResizeTests: XCTestCase {
    func testBucketsRoundUpWithoutExceedingExistingDimensionLimit() {
        for scale: CGFloat in [1, 1.5, 2, 3] {
            for width in stride(from: CGFloat(0.5), through: 5000, by: 7.5) {
                let raw = ThumbnailPixelSize(points: CGSize(width: width, height: 118), scale: scale)
                let bucketed = raw.bucketed
                XCTAssertGreaterThanOrEqual(bucketed.width, raw.width)
                XCTAssertGreaterThanOrEqual(bucketed.height, raw.height)
                XCTAssertLessThan(bucketed.width - raw.width, 32)
                XCTAssertLessThan(bucketed.height - raw.height, 32)
                XCTAssertLessThanOrEqual(bucketed.width, ThumbnailBudget.maximumDimension)
                XCTAssertLessThanOrEqual(bucketed.height, ThumbnailBudget.maximumDimension)
                XCTAssertEqual(bucketed.width % 32, 0)
                XCTAssertEqual(bucketed.bucketed, bucketed)
            }
        }
        for width: CGFloat in [.nan, .infinity, -.infinity, -1, 0] {
            let size = ThumbnailPixelSize(points: CGSize(width: width, height: width), scale: .nan).bucketed
            XCTAssertEqual(size.width, 32)
            XCTAssertEqual(size.height, 32)
        }
    }

    func testControlledRetinaResizeUsesFewerDistinctRequestDimensions() {
        let sizes = stride(from: CGFloat(200), through: 520, by: 0.5).map {
            ThumbnailPixelSize(points: CGSize(width: $0, height: 118), scale: 2)
        }
        let raw = Set(sizes).count
        let bucketed = Set(sizes.map(\.bucketed)).count
        XCTAssertEqual(raw, 641)
        XCTAssertEqual(bucketed, 21)
        print("resize_dimension_keys raw=\(raw) bucketed=\(bucketed); synthetic geometry only")
    }

    func testResizeKeepsPreparedImageAndRejectsObsoleteCompletion() {
        let url = URL(fileURLWithPath: "/temporary/photo.jpg")
        let first = ThumbnailRequest(url: url, kind: "image", width: 416, height: 256)
        let resized = ThumbnailRequest(url: url, kind: "image", width: 448, height: 256)
        let old = NSImage(size: NSSize(width: 1, height: 1))
        let replacement = NSImage(size: NSSize(width: 2, height: 2))
        var presentation = ThumbnailPresentation()
        presentation.begin(first)
        presentation.publish(old, for: first)
        presentation.begin(resized)
        XCTAssertTrue(presentation.image === old)
        presentation.publish(replacement, for: first)
        XCTAssertTrue(presentation.image === old)
        presentation.publish(replacement, for: resized)
        XCTAssertTrue(presentation.image === replacement)
    }

    func testSourceKindOrRemoteCardChangeClearsImageAndRejectsOldResult() {
        let first = ThumbnailRequest(url: URL(fileURLWithPath: "/temporary/photo.jpg"), kind: "image", width: 416, height: 256)
        let other = ThumbnailRequest(url: URL(fileURLWithPath: "/temporary/other.jpg"), kind: "image", width: 416, height: 256)
        let kindChange = ThumbnailRequest(url: first.url, kind: "video", width: 416, height: 256)
        let remote = ThumbnailRequest(url: nil, kind: "video", width: 416, height: 256)
        let image = NSImage(size: NSSize(width: 1, height: 1))
        for next in [other, kindChange, remote] {
            var presentation = ThumbnailPresentation()
            presentation.begin(first)
            presentation.publish(image, for: first)
            presentation.begin(next)
            XCTAssertNil(presentation.image)
            presentation.publish(image, for: first)
            XCTAssertNil(presentation.image)
        }
    }
}
