import XCTest
@testable import Wallmotion

final class RenameDraftTests: XCTestCase {
    func testCounterUsesNormalizedUnicodeGraphemesAndBoundaryStates() {
        let emoji = RenameDraft(text: "  👩🏽‍💻🌅  ")
        XCTAssertEqual(emoji.characterCount, 2)
        for (count, expected) in [(179, RenameDraft.CounterState.normal), (180, .nearLimit), (200, .nearLimit), (201, .exceeded)] {
            let draft = RenameDraft(text: String(repeating: "a", count: count))
            XCTAssertEqual(draft.characterCount, count)
            XCTAssertEqual(draft.counterState, expected)
            XCTAssertEqual(draft.validationError == nil, count <= 200)
        }
        let trimmed = RenameDraft(text: String(repeating: "a", count: 200) + "  ")
        XCTAssertEqual(trimmed.characterCount, 200)
        XCTAssertNil(trimmed.validationError)
    }

    func testRejectedPasteRetainsPreviousTextAndBlocksSaveUntilValidEdit() {
        var draft = RenameDraft(text: "Nome anterior")
        draft.replace(with: String(repeating: "x", count: 257))
        XCTAssertEqual(draft.text, "Nome anterior")
        XCTAssertNotNil(draft.inputError)
        XCTAssertNotNil(draft.validationError)
        draft.replace(with: "Nome anterior")
        XCTAssertNotNil(draft.inputError, "Same-value reconciliation must not unblock Save.")
        draft.replace(with: "Novo nome")
        XCTAssertEqual(draft.text, "Novo nome")
        XCTAssertNil(draft.inputError)
        XCTAssertNil(draft.validationError)
    }

    func testByteLimitPrecedesGraphemeWorkAndLegacyOversizeDoesNotBecomeSilentTruncation() {
        let manyScalars = "a" + String(repeating: "\u{0301}", count: 3000)
        XCTAssertFalse(RenameDraft.accepts(manyScalars))
        let draft = RenameDraft(text: manyScalars)
        XCTAssertEqual(draft.text, "")
        XCTAssertNotNil(draft.validationError)
        XCTAssertTrue(RenameDraft.accepts(String(repeating: "a", count: 256)))
        XCTAssertFalse(RenameDraft.accepts(String(repeating: "a", count: 257)))
    }
}
