import Testing
import Foundation
@testable import Sodalite

/// The overlay scrolls on tvOS only because the text arrives in blocks the focus engine can step
/// through, so the two properties that carry that are pinned here: no block taller than a screen,
/// and no word lost on the way (Sodalite#57).
struct TextBlockSplitterTests {
    private func words(_ value: String) -> [String] {
        value.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    @Test func shortTextStaysOneBlock() {
        let text = "A short biography that fits on screen."
        #expect(TextBlockSplitter.split(text) == [text])
    }

    @Test func paragraphsBecomeTheirOwnBlocks() {
        let blocks = TextBlockSplitter.split("First paragraph.\n\nSecond paragraph.")
        #expect(blocks == ["First paragraph.", "Second paragraph."])
    }

    @Test func aLongParagraphIsCutIntoScreenSizedBlocks() {
        let sentence = "Cruise made his film debut with a minor role in the 1981 romantic drama Endless Love. "
        let paragraph = String(repeating: sentence, count: 30)

        let blocks = TextBlockSplitter.split(paragraph)

        #expect(blocks.count > 1)
        #expect(blocks.allSatisfy { $0.count <= TextBlockSplitter.maxBlockLength })
    }

    /// The cut may move whitespace around; it may not drop or reorder a single word.
    @Test func splittingKeepsEveryWordInOrder() {
        let sentence = "Cruise made his film debut with a minor role in the 1981 romantic drama Endless Love. "
        let text = String(repeating: sentence, count: 20) + "\n\n" + String(repeating: sentence, count: 5)

        let rejoined = TextBlockSplitter.split(text).joined(separator: " ")

        #expect(words(rejoined) == words(text))
    }

    /// A wall of text with no sentence end still has to scroll, so words are the last resort.
    @Test func unpunctuatedTextIsSplitOnWords() {
        let text = String(repeating: "word ", count: 400)

        let blocks = TextBlockSplitter.split(text)

        #expect(blocks.count > 1)
        #expect(blocks.allSatisfy { $0.count <= TextBlockSplitter.maxBlockLength })
        #expect(words(blocks.joined(separator: " ")) == words(text))
    }

    /// A single token longer than a block cannot be cut further, but it must not vanish either.
    @Test func oneOverlongTokenSurvivesAsItsOwnBlock() {
        let token = String(repeating: "a", count: TextBlockSplitter.maxBlockLength + 200)
        #expect(TextBlockSplitter.split(token) == [token])
    }

    /// Empty text still needs a focus target, else the tvOS overlay cannot be left with Menu.
    @Test func blankTextStillYieldsABlock() {
        #expect(TextBlockSplitter.split("").count == 1)
        #expect(TextBlockSplitter.split("   \n\n  ").count == 1)
    }
}
