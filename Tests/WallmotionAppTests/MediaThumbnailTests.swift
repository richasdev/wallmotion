import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Wallmotion

final class MediaThumbnailTests: XCTestCase {
    func testJPEGExifSixThumbnailUsesTransformedPortraitOrientation() throws {
        let url = try makeOrientedImage(type: UTType.jpeg.identifier, orientation: 6)
        defer { try? FileManager.default.removeItem(at: url) }

        let thumbnail = try XCTUnwrap(MediaThumbnailDecoding.imageThumbnail(url: url, targetWidth: 80, targetHeight: 160))
        XCTAssertEqual(thumbnail.width, 20)
        XCTAssertEqual(thumbnail.height, 40)
    }

    func testHEICExifSixThumbnailUsesTransformedPortraitOrientation() throws {
        let url = try makeOrientedImage(type: UTType.heic.identifier, orientation: 6)
        defer { try? FileManager.default.removeItem(at: url) }

        let thumbnail = try XCTUnwrap(MediaThumbnailDecoding.imageThumbnail(url: url, targetWidth: 80, targetHeight: 160))
        XCTAssertEqual(thumbnail.width, 20)
        XCTAssertEqual(thumbnail.height, 40)
    }

    func testMirroredJPEGThumbnailAppliesExifReflection() throws {
        let url = try makeOrientedImage(type: UTType.jpeg.identifier, orientation: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let thumbnail = try XCTUnwrap(MediaThumbnailDecoding.imageThumbnail(url: url, targetWidth: 80, targetHeight: 40))
        var pixels = [UInt8](repeating: 0, count: thumbnail.width * thumbnail.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: thumbnail.width, height: thumbnail.height,
                bitsPerComponent: 8, bytesPerRow: thumbnail.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            )
            context?.draw(thumbnail, in: CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height))
        }
        let leftPixel = 4 * (10 * thumbnail.width + 4)
        XCTAssertGreaterThan(pixels[leftPixel + 2], pixels[leftPixel])
    }

    func testAspectFillDecodeSizeUsesCardGeometryAndSourceAspectRatio() {
        XCTAssertEqual(
            MediaThumbnailDecoding.aspectFillMaximumPixelSize(sourceWidth: 1000, sourceHeight: 2000, targetWidth: 900, targetHeight: 240),
            1800
        )
        XCTAssertEqual(
            MediaThumbnailDecoding.aspectFillMaximumPixelSize(sourceWidth: 4000, sourceHeight: 2000, targetWidth: 800, targetHeight: 240),
            800
        )
    }

    private func makeOrientedImage(type: String, orientation: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionThumbnail-\(UUID()).\(type == UTType.heic.identifier ? "heic" : "jpg")")
        var pixels = [UInt8](repeating: 0, count: 40 * 20 * 4)
        for y in 0..<20 {
            for x in 0..<40 {
                let index = 4 * (y * 40 + x)
                pixels[index + (x < 20 ? 0 : 2)] = 255
                pixels[index + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { throw CocoaError(.fileWriteUnknown) }
        let sourceImage = CGImage(
            width: 40, height: 20, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 160,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(sourceImage), [kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }
}
