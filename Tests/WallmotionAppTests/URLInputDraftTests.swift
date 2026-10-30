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
}
