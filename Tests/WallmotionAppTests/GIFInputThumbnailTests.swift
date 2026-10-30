import AppKit
import Darwin
import XCTest
import WallmotionCore
@testable import Wallmotion

@MainActor
final class GIFInputThumbnailTests: XCTestCase {
    func testOversizedGIFIsRejectedBeforeThumbnailAndSmallGIFStillDecodes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionGIFInputThumb-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sparse.gif")
        let bytes = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0, 0x80, 0, 0,
                          0, 0, 0, 0xff, 0xff, 0xff, 0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0,
                          2, 2, 0x44, 1, 0, 0x3b])
        try bytes.write(to: source)
        let descriptor = open(source.path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        XCTAssertEqual(ftruncate(descriptor, off_t(GIFPreflight.defaultInputBudget + 1)), 0)
        let request = ThumbnailRequest(url: source, kind: MediaKind.gif.rawValue, width: 32, height: 32)
        do {
            _ = try await MediaThumbnailDecoding.generate(request)
            XCTFail("Oversized GIF reached thumbnail decoding")
        } catch {
            XCTAssertEqual(error as? LibraryError, .gifInputTooLarge(limit: GIFPreflight.defaultInputBudget))
        }
        XCTAssertEqual(ftruncate(descriptor, off_t(bytes.count)), 0)
        let image = try await MediaThumbnailDecoding.generate(request)
        XCTAssertEqual(image.width, 1)
        XCTAssertEqual(image.height, 1)
    }
}
