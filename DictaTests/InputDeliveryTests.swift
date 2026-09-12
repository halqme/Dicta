import Foundation
import Testing
@testable import Dicta

@Test
func accessibilityTextEditReplacesCapturedRange() {
    let selection = NSRange(location: 2, length: 2)

    #expect(
        AccessibilityTextEdit.replacingCharacters(
            in: "abcdef",
            range: selection,
            with: "XY"
        ) == "abXYef"
    )
}

@Test
func accessibilityTextEditUsesUTF16OffsetsAndRejectsInvalidRanges() {
    #expect(
        AccessibilityTextEdit.replacingCharacters(
            in: "🙂abc",
            range: NSRange(location: 2, length: 0),
            with: "!"
        ) == "🙂!abc"
    )
    #expect(
        AccessibilityTextEdit.replacingCharacters(
            in: "abc",
            range: NSRange(location: 4, length: 0),
            with: "!"
        ) == nil
    )
}
