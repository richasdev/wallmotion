import AppKit
import XCTest
@testable import Wallmotion

private actor ThumbnailCalls {
    private(set) var requests: [ThumbnailRequest] = []
    private var active = 0
    private(set) var peak = 0
    func begin(_ request: ThumbnailRequest) -> Int {
        requests.append(request); active += 1; peak = max(peak, active)
        return requests.count
    }
    func end() { active -= 1 }
}

@MainActor
final class ThumbnailSchedulerTests: XCTestCase {
    private func request(_ name: String) -> ThumbnailRequest {
        ThumbnailRequest(url: URL(fileURLWithPath: "/tmp/" + name), kind: "image", width: 440, height: 236)
    }
    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }
    private func waitForLoad(_ loader: ThumbnailScheduler, active: Int, pending: Int, subscribers: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            let value = await loader.load
            if value.active == active, value.pending == pending, value.subscribers == subscribers { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Thumbnail scheduler did not reach expected state")
    }
    private func expectCancelled(_ task: Task<CGImage, any Error>) async {
        do { _ = try await task.value; XCTFail("Cancelled subscriber received an image") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testConcurrentLimitAndIdenticalRequestsShareOneDecode() async throws {
        let bitmap = try image(), calls = ThumbnailCalls(), gate = PhotoTestGate()
        let loader = ThumbnailScheduler(maximumConcurrent: 2) { request in
            _ = await calls.begin(request)
            await gate.wait()
            await calls.end()
            return bitmap
        }
        let one = request("one"), two = request("two"), three = request("three")
        let a = Task { try await loader.image(for: one) }
        let duplicate = Task { try await loader.image(for: one) }
        let b = Task { try await loader.image(for: two) }
        let c = Task { try await loader.image(for: three) }
        try await waitForLoad(loader, active: 2, pending: 1, subscribers: 4)
        await gate.release()
        let first = try await a.value, shared = try await duplicate.value
        _ = try await b.value; _ = try await c.value
        XCTAssertTrue(first === shared)
        let requests = await calls.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.filter { $0 == one }.count, 1)
        let peak = await calls.peak
        XCTAssertEqual(peak, 2)
    }

    func testCancellingOneSubscriberKeepsSharedDecoderForOtherSubscriber() async throws {
        let bitmap = try image(), calls = ThumbnailCalls(), gate = PhotoTestGate()
        let loader = ThumbnailScheduler(maximumConcurrent: 1) { request in
            _ = await calls.begin(request); await gate.wait(); await calls.end(); return bitmap
        }
        let key = request("same")
        let first = Task { try await loader.image(for: key) }
        let second = Task { try await loader.image(for: key) }
        try await waitForLoad(loader, active: 1, pending: 0, subscribers: 2)
        first.cancel()
        await expectCancelled(first)
        try await waitForLoad(loader, active: 1, pending: 0, subscribers: 1)
        await gate.release()
        let result = try await second.value
        XCTAssertTrue(result === bitmap)
        let requests = await calls.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testCancelledQueuedRequestNeverStartsDecoder() async throws {
        let bitmap = try image(), calls = ThumbnailCalls(), gate = PhotoTestGate()
        let loader = ThumbnailScheduler(maximumConcurrent: 1) { request in
            _ = await calls.begin(request); await gate.wait(); await calls.end(); return bitmap
        }
        let first = Task { try await loader.image(for: request("first")) }
        try await waitForLoad(loader, active: 1, pending: 0, subscribers: 1)
        let queued = Task { try await loader.image(for: request("cancelled")) }
        try await waitForLoad(loader, active: 1, pending: 1, subscribers: 2)
        queued.cancel()
        await expectCancelled(queued)
        try await waitForLoad(loader, active: 1, pending: 0, subscribers: 1)
        await gate.release()
        _ = try await first.value
        let requests = await calls.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testCancelledCodecKeepsSlotUntilReturnAndFreshSameKeyGetsNewGeneration() async throws {
        let bitmap = try image(), calls = ThumbnailCalls(), gate = PhotoTestGate()
        let loader = ThumbnailScheduler(maximumConcurrent: 1) { request in
            let ordinal = await calls.begin(request)
            if ordinal == 1 { await gate.wait() } // Deliberately ignores cancellation.
            await calls.end(); return bitmap
        }
        let key = request("same")
        let obsolete = Task { try await loader.image(for: key) }
        try await waitForLoad(loader, active: 1, pending: 0, subscribers: 1)
        obsolete.cancel()
        await expectCancelled(obsolete)
        let fresh = Task { try await loader.image(for: key) }
        try await waitForLoad(loader, active: 1, pending: 1, subscribers: 1)
        await gate.release()
        let result = try await fresh.value
        XCTAssertTrue(result === bitmap)
        let requests = await calls.requests, peak = await calls.peak
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(peak, 1)
        try await waitForLoad(loader, active: 0, pending: 0, subscribers: 0)
    }
    func testDecodeFailureReleasesSlotAndResumesEverySubscriber() async throws {
        enum Failure: Error { case decode }
        let bitmap = try image(), calls = ThumbnailCalls(), gate = PhotoTestGate()
        let failedKey = request("failed")
        let loader = ThumbnailScheduler(maximumConcurrent: 1) { request in
            _ = await calls.begin(request)
            if request == failedKey { await gate.wait(); await calls.end(); throw Failure.decode }
            await calls.end(); return bitmap
        }
        let a = Task { try await loader.image(for: failedKey) }
        let b = Task { try await loader.image(for: failedKey) }
        try await waitForLoad(loader, active: 1, pending: 0, subscribers: 2)
        let next = Task { try await loader.image(for: request("next")) }
        try await waitForLoad(loader, active: 1, pending: 1, subscribers: 3)
        await gate.release()
        for task in [a, b] {
            do { _ = try await task.value; XCTFail("Decoder failure was ignored") }
            catch { XCTAssertTrue(error is Failure) }
        }
        let result = try await next.value
        XCTAssertTrue(result === bitmap)
        let requests = await calls.requests
        XCTAssertEqual(requests.count, 2)
        try await waitForLoad(loader, active: 0, pending: 0, subscribers: 0)
    }

    func testAlreadyCancelledSubscriberNeverQueuesDecoder() async throws {
        let bitmap = try image(), calls = ThumbnailCalls(), gate = PhotoTestGate()
        let loader = ThumbnailScheduler { request in
            _ = await calls.begin(request); await calls.end(); return bitmap
        }
        let task = Task { await gate.wait(); return try await loader.image(for: request("cancelled")) }
        task.cancel()
        await gate.release()
        await expectCancelled(task)
        let requests = await calls.requests
        XCTAssertTrue(requests.isEmpty)
        try await waitForLoad(loader, active: 0, pending: 0, subscribers: 0)
    }

}
