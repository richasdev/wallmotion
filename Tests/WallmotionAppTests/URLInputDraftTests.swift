import Foundation
import XCTest
@testable import Wallmotion

final class URLInputDraftTests: XCTestCase {
    func testOversizedPastePreservesSignedURLAndBlocksUntilValidReplacement() {
        let original = "https://cdn.example.com/live.m3u8?token=PRIVATE_TOKEN"
        var draft = URLInputDraft(text: original)
        draft.replace(with: String(repeating: "x", count: 4097))
        XCTAssertEqual(draft.text, original)
        XCTAssertNotNil(draft.inputError)
        XCTAssertFalse(draft.inputError?.contains("PRIVATE_TOKEN") == true)
        draft.replace(with: original)
        XCTAssertNotNil(draft.inputError, "A same-value field write must not acknowledge rejected input.")
        let replacement = "https://youtu.be/dQw4w9WgXcQ?t=90"
        draft.replace(with: replacement)
        XCTAssertEqual(draft.text, replacement)
        XCTAssertNil(draft.inputError)
    }

    func testExactByteBoundaryAndMultibyteGraphemesUseUTF8NotCharacterCount() {
        XCTAssertTrue(URLInputDraft.accepts(String(repeating: "a", count: 4096)))
        XCTAssertFalse(URLInputDraft.accepts(String(repeating: "a", count: 4097)))
        XCTAssertTrue(URLInputDraft.accepts(String(repeating: "🌅", count: 1024)))
        XCTAssertFalse(URLInputDraft.accepts(String(repeating: "🌅", count: 1025)))
        XCTAssertFalse(URLInputDraft.accepts("a" + String(repeating: "\u{0301}", count: 3000)))
    }

    func testOversizedInitialURLDoesNotBecomePartialSavableLink() {
        let draft = URLInputDraft(text: "https://example.com/" + String(repeating: "a", count: 4096))
        XCTAssertEqual(draft.text, "")
        XCTAssertNotNil(draft.inputError)
        XCTAssertTrue(URLInputDraft(text: "").text.isEmpty)
        XCTAssertNil(URLInputDraft(text: "").inputError)
    }
    func testCanonicalURLNormalizationEditPreservesExactBytesAndEncodedPath() {
        let original = "https://example.com/caf\u{00E9}.mp4"
        let incoming = "https://example.com/cafe\u{0301}.mp4"
        XCTAssertEqual(original, incoming, "Swift String equality is canonical, not byte identity")
        XCTAssertNotEqual(URL(string: original)?.absoluteString, URL(string: incoming)?.absoluteString)
        var draft = URLInputDraft(text: original)
        draft.replace(with: incoming)
        XCTAssertTrue(draft.text.utf8.elementsEqual(incoming.utf8))
        XCTAssertEqual(URL(string: draft.text)?.absoluteString, URL(string: incoming)?.absoluteString)
    }

    func testOversizeCanonicalEquivalentPasteStillSetsErrorAndExactWritebackKeepsIt() {
        let original = "https://example.com/" + String(repeating: "\u{00E9}", count: 1500)
        let incoming = "https://example.com/" + String(repeating: "e\u{0301}", count: 1500)
        XCTAssertEqual(original, incoming)
        XCTAssertTrue(URLInputDraft.accepts(original))
        XCTAssertFalse(URLInputDraft.accepts(incoming))
        var draft = URLInputDraft(text: original)
        draft.replace(with: incoming)
        XCTAssertTrue(draft.text.utf8.elementsEqual(original.utf8))
        XCTAssertNotNil(draft.inputError)
        draft.replace(with: original)
        XCTAssertNotNil(draft.inputError)
        draft.replace(with: original + "x")
        XCTAssertNil(draft.inputError)
    }

}
