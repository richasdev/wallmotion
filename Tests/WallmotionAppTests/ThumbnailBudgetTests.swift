import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
import WallmotionCore
@testable import Wallmotion

final class ThumbnailBudgetTests: XCTestCase {
    func testGeometryClampsBeforeIntegerConversionAndHandlesInvalidScale() {
        let invalid = ThumbnailPixelSize(points: CGSize(width: CGFloat.nan, height: CGFloat.infinity), scale: 2)
        XCTAssertEqual(invalid.width, 1)
        XCTAssertEqual(invalid.height, 1)
        let huge = ThumbnailPixelSize(points: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 100), scale: CGFloat.greatestFiniteMagnitude)
        XCTAssertEqual(huge.width, ThumbnailBudget.maximumDimension)
        XCTAssertEqual(huge.height, ThumbnailBudget.maximumDimension)
        for scale in [CGFloat.zero, -1, .nan, .infinity] {
            XCTAssertEqual(ThumbnailPixelSize(points: CGSize(width: 220, height: 118), scale: scale), ThumbnailPixelSize(points: CGSize(width: 220, height: 118), scale: 1))
        }
        XCTAssertEqual(ThumbnailPixelSize(points: CGSize(width: -1, height: 0), scale: 2).width, 1)
    }

    func testAspectFillBudgetPreservesSmallCardsAndBoundsExtremeMetadata() {
        let sources = [CGSize(width: 1000, height: 2000), CGSize(width: 4000, height: 2000), CGSize(width: 100_000, height: 1), CGSize(width: CGFloat.greatestFiniteMagnitude, height: 10)]
        for source in sources {
            let limit = ThumbnailBudget.pixelLimit(source: source, target: CGSize(width: Int.max, height: Int.max))
            XCTAssertTrue((1...4096).contains(limit))
            XCTAssertLessThanOrEqual(PhotoDecodeBudget.estimatedBytes(for: source, pixelLimit: limit), ThumbnailBudget.maximumBytes)
        }
        XCTAssertEqual(ThumbnailBudget.pixelLimit(source: CGSize(width: 4000, height: 2000), target: CGSize(width: 440, height: 236)), 472)
        for size in [CGSize.zero, CGSize(width: CGFloat.nan, height: 1), CGSize(width: 1, height: CGFloat.infinity)] {
            XCTAssertFalse(ThumbnailBudget.validSource(size))
            XCTAssertEqual(ThumbnailBudget.pixelLimit(source: size, target: CGSize(width: 400, height: 200)), 1)
        }
    }

    func testActualBitmapCostRejectsOversizedOutputWithoutOverflowing() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2048, height: 2048, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        XCTAssertNil(ThumbnailBudget.cost(of: try XCTUnwrap(context.makeImage())))
        let small = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(small.makeImage())
        XCTAssertEqual(ThumbnailBudget.cost(of: image), image.bytesPerRow * image.height)
    }

    func testLargePortraitDecodeFitsBudgetAndPreservesOrientation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionBudget-\(UUID()).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 2048, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let source = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, source, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let image = try XCTUnwrap(MediaThumbnailDecoding.imageThumbnail(url: url, targetWidth: Int.max, targetHeight: Int.max))
        XCTAssertGreaterThan(image.height, image.width)
        XCTAssertLessThanOrEqual(image.height, 1024)
        XCTAssertLessThanOrEqual(try XCTUnwrap(ThumbnailBudget.cost(of: image)), ThumbnailBudget.maximumBytes)
    }
}
