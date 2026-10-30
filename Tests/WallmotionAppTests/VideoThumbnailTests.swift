import AppKit
import XCTest
@testable import Wallmotion

@MainActor
final class VideoThumbnailTests: XCTestCase {
    private func request(_ url: URL, width: Int = 80) -> ThumbnailRequest {
        ThumbnailRequest(url: url, kind: "video", width: width, height: 160)
    }
    private func fixture(rotated: Bool = false) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionVideoThumbnail-\(UUID()).mp4")
        do { try await LocalVideoFixture.write(at: url, rotated: rotated); return url }
        catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    private func awaitIdle(_ scheduler: ThumbnailScheduler) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let load = await scheduler.load
            if load.active == 0, load.pending == 0, load.subscribers == 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Video thumbnail scheduler did not drain")
        throw NSError(domain: "WallmotionThumbnailQA", code: 1)
    }

    func testNativeH264ThumbnailPreservesRotationAndFitsBitmapBudget() async throws {
        let url = try await fixture(rotated: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let scheduler = ThumbnailScheduler(maximumConcurrent: 1)
        let image = try await scheduler.image(for: request(url))
        XCTAssertEqual(image.width, 16)
        XCTAssertEqual(image.height, 32)
        XCTAssertNotNil(ThumbnailBudget.cost(of: image))
        try await awaitIdle(scheduler)
    }

    func testVideoGenerationRejectsNonlocalSourcesBeforeCreatingAsset() async {
        for text in ["https://127.0.0.1:1/never-fetch.mp4", "file://remotehost/private/video.mp4"] {
            do {
                _ = try await MediaThumbnailDecoding.generate(request(URL(string: text)!))
                XCTFail("Thumbnail generator accepted a nonlocal source")
            } catch { XCTAssertEqual(error as? ThumbnailError, .unavailable) }
        }
    }

    func testCancelledNativeVideoRequestDrainsAndNextRequestSucceeds() async throws {
        let url = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let entered = expectation(description: "native decode operation entered")
        let scheduler = ThumbnailScheduler(maximumConcurrent: 1) { request in
            if request.width == 80 { entered.fulfill() }
            return try await MediaThumbnailDecoding.generate(request)
        }
        let first = Task { try await scheduler.image(for: request(url)) }
        await fulfillment(of: [entered], timeout: 2)
        first.cancel()
        var outcome = "completed-before-cancel"
        do { _ = try await first.value }
        catch {
            XCTAssertTrue(error is CancellationError)
            outcome = "subscriber-cancelled"
        }
        try await awaitIdle(scheduler)
        // A fresh dimension creates a new request, independent of any prior result.
        let next = try await scheduler.image(for: request(url, width: 96))
        XCTAssertGreaterThan(next.width, next.height)
        XCTAssertNotNil(ThumbnailBudget.cost(of: next))
        try await awaitIdle(scheduler)
        print("VIDEO_THUMBNAIL_CANCEL outcome=\(outcome) drained=true subsequent_native_frame=true")
        // This observes the real native path but does not force a particular
        // AVFoundation phase: completion may legitimately win the race.
    }
}
