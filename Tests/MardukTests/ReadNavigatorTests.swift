import XCTest
@testable import marduk

final class ReadNavigatorTests: XCTestCase {

    // Three sentences, one paragraph. Offsets (UTF-16):
    // "The quick fox jumps. " starts at 0
    // "A second sentence follows here. " starts at 21
    // "The third one ends it." starts at 53
    private let threeSentences =
        "The quick fox jumps. A second sentence follows here. The third one ends it."

    // Two paragraphs split by a blank line; second starts at 42.
    private let twoParagraphs =
        "First paragraph with two sentences. Yes.\n\nSecond paragraph starts here. It continues on."

    // MARK: - Sentence back

    func testBackMidSentenceRestartsIt() {
        // Position 40 is deep inside sentence 2 (starts at 21)
        XCTAssertEqual(ReadNavigator.target(in: threeSentences, from: 40,
                                            unit: .sentence, direction: .back), 21)
    }

    func testBackWithinGraceGoesToPreviousSentence() {
        // Position 25 is only 4 units into sentence 2 — inside the grace
        // window, so back travels to sentence 1 instead of restarting
        XCTAssertEqual(ReadNavigator.target(in: threeSentences, from: 25,
                                            unit: .sentence, direction: .back), 0)
    }

    func testBackAtExactStartGoesToPreviousSentence() {
        XCTAssertEqual(ReadNavigator.target(in: threeSentences, from: 21,
                                            unit: .sentence, direction: .back), 0)
    }

    func testBackClampsToZeroInFirstSentence() {
        XCTAssertEqual(ReadNavigator.target(in: threeSentences, from: 10,
                                            unit: .sentence, direction: .back), 0)
        XCTAssertEqual(ReadNavigator.target(in: threeSentences, from: 0,
                                            unit: .sentence, direction: .back), 0)
    }

    func testAbbreviationDoesNotSplitSentence() {
        let text = "Dr. Smith arrived early. The meeting began."
        // Position inside "arrived" — the sentence containing it starts at 0,
        // not after "Dr."
        XCTAssertEqual(ReadNavigator.target(in: text, from: 15,
                                            unit: .sentence, direction: .back), 0)
    }

    // MARK: - Sentence forward

    func testForwardGoesToNextSentence() {
        XCTAssertEqual(ReadNavigator.target(in: threeSentences, from: 5,
                                            unit: .sentence, direction: .forward), 21)
        XCTAssertEqual(ReadNavigator.target(in: threeSentences, from: 25,
                                            unit: .sentence, direction: .forward), 53)
    }

    func testForwardInLastSentenceIsNoOp() {
        XCTAssertEqual(ReadNavigator.target(in: threeSentences, from: 60,
                                            unit: .sentence, direction: .forward), 60)
    }

    // MARK: - Words

    func testWordBackFromWordStartIsPreviousWord() {
        // "The quick fox…": "quick" starts at 4, "The" at 0. Boundary
        // callbacks sit on word starts, so grace is zero.
        XCTAssertEqual(ReadNavigator.target(in: threeSentences, from: 4,
                                            unit: .word, direction: .back), 0)
    }

    func testWordForward() {
        XCTAssertEqual(ReadNavigator.target(in: threeSentences, from: 4,
                                            unit: .word, direction: .forward), 10)
    }

    // MARK: - Paragraphs

    func testParagraphForwardCrossesBlankLine() {
        XCTAssertEqual(ReadNavigator.target(in: twoParagraphs, from: 10,
                                            unit: .paragraph, direction: .forward), 42)
    }

    func testParagraphBackFromSecondParagraph() {
        // Deep in paragraph 2 (starts at 42): back restarts it
        XCTAssertEqual(ReadNavigator.target(in: twoParagraphs, from: 80,
                                            unit: .paragraph, direction: .back), 42)
        // Within the grace of its start: back travels to paragraph 1
        XCTAssertEqual(ReadNavigator.target(in: twoParagraphs, from: 50,
                                            unit: .paragraph, direction: .back), 0)
    }

    func testParagraphsFallBackToLinesWithoutBlankLines() {
        let text = "Line one here.\nLine two here."
        XCTAssertEqual(ReadNavigator.target(in: text, from: 5,
                                            unit: .paragraph, direction: .forward), 15)
    }

    func testBlankLinesTrumpSingleNewlinesForParagraphs() {
        // Lines at 0, 10, 21; the only PARAGRAPH break is the blank line
        // before 21 — paragraph-forward from line 1 skips line 2
        let text = "One line.\nTwo line.\n\nNew para."
        XCTAssertEqual(ReadNavigator.target(in: text, from: 2,
                                            unit: .paragraph, direction: .forward), 21)
        XCTAssertEqual(ReadNavigator.target(in: text, from: 2,
                                            unit: .line, direction: .forward), 10)
    }

    // MARK: - Lines

    func testLineForwardAndBack() {
        // Line 2 starts at 22 and is longer than the 12-unit grace
        let text = "A first line of text.\nThe second line is long enough."
        XCTAssertEqual(ReadNavigator.target(in: text, from: 5,
                                            unit: .line, direction: .forward), 22)
        // Deep in line 2: back restarts it…
        XCTAssertEqual(ReadNavigator.target(in: text, from: 40,
                                            unit: .line, direction: .back), 22)
        // …but within the grace of its start: previous line
        XCTAssertEqual(ReadNavigator.target(in: text, from: 26,
                                            unit: .line, direction: .back), 0)
    }

    func testLineStart() {
        let text = "One line.\nTwo line.\n\nNew para."
        XCTAssertEqual(ReadNavigator.lineStart(in: text, at: 15), 10)
        // No grace: at the line's own start it stays put (caller's no-op)
        XCTAssertEqual(ReadNavigator.lineStart(in: text, at: 10), 10)
        XCTAssertEqual(ReadNavigator.lineStart(in: text, at: 5), 0)
        XCTAssertEqual(ReadNavigator.lineStart(in: "", at: 0), 0)
    }

    func testSingleParagraphBackRestartsRead() {
        let text = "Just one paragraph of text with no breaks at all."
        XCTAssertEqual(ReadNavigator.target(in: text, from: 40,
                                            unit: .paragraph, direction: .back), 0)
    }

    // MARK: - Edges / degenerate input

    func testEmptyAndWhitespaceTextAreNoOps() {
        XCTAssertEqual(ReadNavigator.target(in: "", from: 0,
                                            unit: .sentence, direction: .back), 0)
        XCTAssertEqual(ReadNavigator.target(in: "   \n  ", from: 3,
                                            unit: .word, direction: .forward), 3)
    }

    func testEndTargetIsLastParagraphStart() {
        XCTAssertEqual(ReadNavigator.endTarget(in: twoParagraphs), 42)
        XCTAssertEqual(ReadNavigator.endTarget(in: "single block"), 0)
        XCTAssertEqual(ReadNavigator.endTarget(in: ""), 0)
    }

    // MARK: - Search

    func testSearchForwardFindsNextOccurrence() {
        // "sentence" occurs at 30 (in sentence 2, which starts at 21) —
        // a hit lands at the containing sentence's start
        XCTAssertEqual(ReadNavigator.searchTarget(in: threeSentences, from: 5,
                                                  query: "sentence",
                                                  direction: .forward), 21)
    }

    func testSearchBackwardFindsLastBefore() {
        XCTAssertEqual(ReadNavigator.searchTarget(in: threeSentences, from: 60,
                                                  query: "quick",
                                                  direction: .back), 0)
    }

    func testSearchSmartcase() {
        // All-lowercase matches case-insensitively
        XCTAssertNotNil(ReadNavigator.searchTarget(in: threeSentences, from: 30,
                                                   query: "the",
                                                   direction: .forward))
        // A capital demands exact case: "THE" appears nowhere
        XCTAssertNil(ReadNavigator.searchTarget(in: threeSentences, from: 0,
                                                query: "THE quick",
                                                direction: .forward))
        // Exact case still matches when it exists
        XCTAssertEqual(ReadNavigator.searchTarget(in: threeSentences, from: 30,
                                                  query: "The third",
                                                  direction: .forward), 53)
    }

    func testSearchDoesNotWrap() {
        XCTAssertNil(ReadNavigator.searchTarget(in: threeSentences, from: 60,
                                                query: "quick",
                                                direction: .forward))
        XCTAssertNil(ReadNavigator.searchTarget(in: threeSentences, from: 0,
                                                query: "quick",
                                                direction: .back))
    }

    func testSearchCurrentWordNotItsOwnMatch() {
        // Voice sits exactly on "quick" (position 4): forward search for it
        // must not find the word being spoken right now
        XCTAssertNil(ReadNavigator.searchTarget(in: threeSentences, from: 4,
                                                query: "quick",
                                                direction: .forward))
    }

    func testSearchEmptyQueryIsNil() {
        XCTAssertNil(ReadNavigator.searchTarget(in: threeSentences, from: 10,
                                                query: "", direction: .forward))
    }
}
