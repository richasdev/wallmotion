import Foundation
import XCTest
@testable import Wallmotion

@MainActor
final class MediaDropIntentTests: XCTestCase {
    func testFilesPreserveOrderAndDuplicatesWithoutCheckingOrOpeningPaths() {
        let files = [URL(fileURLWithPath: "/not-accessed/a.png"), URL(fileURLWithPath: "/not-accessed/b.mp4"), URL(fileURLWithPath: "/not-accessed/a.png")]
        guard case .files(let result) = MediaDropIntent.classify(files) else { return XCTFail("Files were not classified") }
        XCTAssertEqual(result, files)
    }

    func testSingleProviderAndDirectLinksCreateReviewDraftsWithOriginalQuery() throws {
        let youtube = try XCTUnwrap(URL(string: "https://youtu.be/dQw4w9WgXcQ?t=90"))
        guard case .link(let web) = MediaDropIntent.classify([youtube]) else { return XCTFail("Missing provider draft") }
        XCTAssertTrue(web.web)
        XCTAssertEqual(web.text, youtube.absoluteString)
        let direct = try XCTUnwrap(URL(string: "https://cdn.example.com/live.m3u8?token=PRIVATE_TOKEN"))
        guard case .link(let draft) = MediaDropIntent.classify([direct]) else { return XCTFail("Missing direct draft") }
        XCTAssertFalse(draft.web)
        XCTAssertEqual(draft.text, direct.absoluteString)
        XCTAssertNotEqual(draft.id, web.id)
    }

    func testMixedFilesAndLinksOrMultipleLinksRejectWholeDrop() throws {
        let link = try XCTUnwrap(URL(string: "https://cdn.example.com/video.mp4?token=PRIVATE_TOKEN"))
        for urls in [[URL(fileURLWithPath: "/not-accessed/a.png"), link], [link, link]] {
            guard case .rejected(let message) = MediaDropIntent.classify(urls) else { return XCTFail("Partial classification accepted") }
            XCTAssertFalse(message.contains("PRIVATE_TOKEN"))
        }
    }

    func testUnsafeAndOversizeLinksNeverCreateDraftOrEchoInputInError() throws {
        for text in ["http://example.com/PRIVATE_TOKEN.mp4", "https://user:PRIVATE_TOKEN@example.com/video.mp4", "https://www.youtube.com/playlist?list=PRIVATE_TOKEN", "https://example.com/" + String(repeating: "a", count: 4096)] {
            let url = try XCTUnwrap(URL(string: text))
            guard case .rejected(let message) = MediaDropIntent.classify([url]) else { return XCTFail("Unsafe URL became a draft") }
            XCTAssertFalse(message.contains("PRIVATE_TOKEN"))
        }
        guard case .rejected = MediaDropIntent.classify(Array(repeating: URL(fileURLWithPath: "/not-accessed/a.png"), count: 257)) else {
            return XCTFail("Oversized file drop accepted")
        }
    }
}
