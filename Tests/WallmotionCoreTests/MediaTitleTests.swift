import Foundation
import Testing
@testable import WallmotionCore

struct MediaTitleTests {
    @Test func trimsOuterSpaceAndPreservesUnicodeAndEmoji() throws {
        #expect(try MediaTitle.normalized("  Céu de Tóquio 👨‍👩‍👧‍👦  ") == "Céu de Tóquio 👨‍👩‍👧‍👦")
        #expect(try MediaTitle.normalized("東京の夜") == "東京の夜")
    }

    @Test func rejectsEmptyMultilineControlAndDirectionalOverrides() {
        for title in ["", " \n\t "] {
            #expect(throws: MediaTitleError.empty) { try MediaTitle.normalized(title) }
        }
        for title in ["a\nb", "a\tb", "a\0b", "a\u{2028}b", "a\u{202e}b"] {
            #expect(throws: MediaTitleError.invalidCharacters) { try MediaTitle.normalized(title) }
        }
    }

    @Test func characterBoundaryAndLongSingleGraphemeAreBounded() throws {
        #expect(try MediaTitle.normalized(String(repeating: "a", count: 200)).count == 200)
        #expect(throws: MediaTitleError.tooLong) { try MediaTitle.normalized(String(repeating: "a", count: 201)) }
        let combined = "a" + String(repeating: "\u{0301}", count: 3000)
        #expect(combined.count == 1)
        #expect(throws: MediaTitleError.tooLong) { try MediaTitle.normalized(combined) }
    }
}
