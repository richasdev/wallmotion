import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
import WallmotionCore
@testable import Wallmotion

final class PhotoDecodingTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionPhoto-\(UUID()).tiff")
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: 120, height: 60, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    @MainActor func testWorkerDecodesOutsideMainAndPreservesOrientedSourceGeometry() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let worker = PhotoDecodeWorker(decodeImage: { request in
            XCTAssertFalse(Thread.isMainThread, "ImageIO must run on the worker executor")
            return try PhotoDecodeWorker.decodeImage(request)
        })
        let photo = try await worker.decode(PhotoDecodeRequest(url: url, mediaFit: .fit, viewportWidth: 30, viewportHeight: 30))
        XCTAssertEqual(photo.sourceSize, CGSize(width: 60, height: 120))
        XCTAssertEqual(photo.image.width, 15)
        XCTAssertEqual(photo.image.height, 30)
        XCTAssertLessThanOrEqual(photo.image.bytesPerRow * photo.image.height, PhotoDecodeBudget.maximumBytes)
    }

    func testCancelledWorkerCannotPublishCompletedCodecOutput() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let entered = expectation(description: "Codec entered")
        let release = DispatchSemaphore(value: 0)
        let worker = PhotoDecodeWorker(decodeImage: { request in
            entered.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw PhotoDecodingError.unreadable }
            return try PhotoDecodeWorker.decodeImage(request)
        })
        let task = Task { try await worker.decode(PhotoDecodeRequest(url: url, mediaFit: .fit, viewportWidth: 30, viewportHeight: 30)) }
        await fulfillment(of: [entered], timeout: 3)
        task.cancel()
        release.signal()
        do { _ = try await task.value; XCTFail("Cancelled output must not be published") }
        catch is CancellationError { }
    }

    func testUnreadablePhotoFailsWithoutRetainingOutput() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            _ = try await PhotoDecodeWorker.shared.decode(PhotoDecodeRequest(url: missing, mediaFit: .fill, viewportWidth: 100, viewportHeight: 100))
            XCTFail("Missing file must fail")
        } catch PhotoDecodingError.unreadable { }
    }
}
