import AppKit
import XCTest
import WallmotionCore
@testable import Wallmotion

private actor PhotoTestGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
final class PhotoPreparationTests: XCTestCase {
    private func photo() throws -> DecodedPhoto {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return DecodedPhoto(image: try XCTUnwrap(context.makeImage()), sourceSize: CGSize(width: 2, height: 2))
    }

    private func request(_ name: String) -> PhotoDecodeRequest {
        PhotoDecodeRequest(url: URL(fileURLWithPath: "/tmp/" + name), mediaFit: .fit, viewportWidth: 20, viewportHeight: 20)
    }

    func testReplacingPendingSelectionPublishesOnlyNewestBatch() async throws {
        let gate = PhotoTestGate()
        let oldEntered = expectation(description: "old decode entered")
        let finished = expectation(description: "new completion")
        let image = try photo()
        let old = request("old")
        let latest = request("new")
        let loader = PhotoPreparation(decode: { value in
            if value == old { oldEntered.fulfill(); await gate.wait() }
            return image
        })
        loader.submit(["left": old]) { _ in XCTFail("Stale selection published") }
        await fulfillment(of: [oldEntered], timeout: 2)
        loader.submit(["left": latest]) { results in
            XCTAssertEqual(try? results["left"]?.get().sourceSize, image.sourceSize)
            finished.fulfill()
        }
        await gate.release()
        await fulfillment(of: [finished], timeout: 2)
        loader.cancel()
    }

    func testSamePendingPixelsReuseDecodeAndLatestCompletion() async throws {
        let gate = PhotoTestGate()
        let entered = expectation(description: "decode entered")
        entered.assertForOverFulfill = true
        let finished = expectation(description: "latest policy completion")
        let image = try photo()
        let value = request("same")
        let loader = PhotoPreparation(decode: { _ in entered.fulfill(); await gate.wait(); return image })
        loader.submit(["left": value, "right": value]) { _ in XCTFail("Old policy completion used") }
        await fulfillment(of: [entered], timeout: 2)
        loader.submit(["left": value, "right": value]) { results in
            XCTAssertEqual(results.count, 2)
            XCTAssertTrue((try? results["left"]?.get().image) === (try? results["right"]?.get().image))
            finished.fulfill()
        }
        await gate.release()
        await fulfillment(of: [finished], timeout: 2)
        loader.cancel()
    }

    func testStopDiscardsEvenAnUncooperativeDecoderResult() async throws {
        let gate = PhotoTestGate()
        let entered = expectation(description: "decode entered")
        let stale = expectation(description: "must not complete")
        stale.isInverted = true
        let image = try photo()
        let loader = PhotoPreparation(decode: { _ in entered.fulfill(); await gate.wait(); return image })
        loader.submit(["left": request("cancelled")]) { _ in stale.fulfill() }
        await fulfillment(of: [entered], timeout: 2)
        loader.cancel()
        await gate.release()
        await fulfillment(of: [stale], timeout: 0.1)
    }
}
