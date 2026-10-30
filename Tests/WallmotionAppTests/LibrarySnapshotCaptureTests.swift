import AppKit
import XCTest

@MainActor
final class LibrarySnapshotCaptureTests: XCTestCase {
    private func bitmap(content: Bool, opaque: Bool = true) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<64 {
            for x in 0..<64 {
                let color: (UInt8, UInt8, UInt8) = !content ? (32, 32, 32) : (y < 20 ? (255, 0, 0) : (x < 32 ? (0, 255, 0) : (0, 0, 255)))
                let offset = y * bitmap.bytesPerRow + x * 4
                pixels[offset] = color.0; pixels[offset + 1] = color.1
                pixels[offset + 2] = color.2; pixels[offset + 3] = opaque ? 255 : 0
            }
        }
        return bitmap
    }

    func testDetectorRejectsUniformAndAcceptsDistinctRenderedRegions() throws {
        XCTAssertFalse(LibrarySnapshotCapture.hasContent(try bitmap(content: false)))
        XCTAssertTrue(LibrarySnapshotCapture.hasContent(try bitmap(content: true)))
        XCTAssertFalse(LibrarySnapshotCapture.hasContent(try bitmap(content: true, opaque: false)))
    }

    func testRetriesUntilContentIsAvailable() async throws {
        let uniform = try bitmap(content: false), rendered = try bitmap(content: true)
        var calls = 0
        let result = try await LibrarySnapshotCapture.waitForContent(interval: .milliseconds(1)) {
            calls += 1
            return calls == 1 ? uniform : rendered
        }
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(result === rendered)
    }

    func testUniformCaptureExpiresWithExplicitFailure() async throws {
        let uniform = try bitmap(content: false)
        do {
            _ = try await LibrarySnapshotCapture.waitForContent(timeout: .milliseconds(20), interval: .milliseconds(5)) { uniform }
            XCTFail("Uniform capture must not pass visual QA")
        } catch LibrarySnapshotCapture.Failure.noRenderedContent { }
    }

    func testCancellationStopsBeforeCapturing() async {
        var calls = 0
        let task = Task {
            _ = try await LibrarySnapshotCapture.waitForContent {
                calls += 1
                return nil
            }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled capture completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 0)
    }
}
