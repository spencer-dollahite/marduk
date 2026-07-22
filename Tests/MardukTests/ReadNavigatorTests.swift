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

    // MARK: - Spell (unitText + spellOut)

    func testUnitTextWord() {
        // Mid-word, at its start, and in the following gap all yield it
        XCTAssertEqual(ReadNavigator.unitText(in: threeSentences, at: 6,
                                              unit: .word), "quick")
        XCTAssertEqual(ReadNavigator.unitText(in: threeSentences, at: 4,
                                              unit: .word), "quick")
        XCTAssertEqual(ReadNavigator.unitText(in: threeSentences, at: 9,
                                              unit: .word), "quick")
    }

    func testUnitTextSentence() {
        XCTAssertEqual(ReadNavigator.unitText(in: threeSentences, at: 25,
                                              unit: .sentence)?
                           .hasPrefix("A second sentence"), true)
    }

    func testUnitTextEmptyAndUnsupported() {
        XCTAssertNil(ReadNavigator.unitText(in: "", at: 0, unit: .word))
        XCTAssertNil(ReadNavigator.unitText(in: "abc", at: 1, unit: .line))
    }

    // MARK: - Char find (f/F)

    func testFindCharForwardAndBack() {
        // "The quick fox jumps." — "q" at 4, "x" at 12
        XCTAssertEqual(ReadNavigator.findChar(in: threeSentences, from: 0,
                                              char: "q", direction: .forward), 4)
        XCTAssertEqual(ReadNavigator.findChar(in: threeSentences, from: 20,
                                              char: "x", direction: .back), 12)
    }

    func testFindCharExcludesCurrentPositionAndCase() {
        // Forward starts strictly after the position
        XCTAssertEqual(ReadNavigator.findChar(in: "aXa", from: 0,
                                              char: "a", direction: .forward), 2)
        // Case-sensitive, vim-style
        XCTAssertEqual(ReadNavigator.findChar(in: "aXa", from: 0,
                                              char: "X", direction: .forward), 1)
        XCTAssertNil(ReadNavigator.findChar(in: "aXa", from: 0,
                                            char: "x", direction: .forward))
    }

    func testFindCharNoMatchIsNil() {
        XCTAssertNil(ReadNavigator.findChar(in: threeSentences, from: 60,
                                            char: "q", direction: .forward))
        XCTAssertNil(ReadNavigator.findChar(in: threeSentences, from: 3,
                                            char: "q", direction: .back))
    }

    func testWordStart() {
        XCTAssertEqual(ReadNavigator.wordStart(in: threeSentences, at: 6), 4)
        XCTAssertEqual(ReadNavigator.wordStart(in: threeSentences, at: 4), 4)
        XCTAssertEqual(ReadNavigator.wordStart(in: "", at: 0), 0)
    }

    // MARK: - Headings (]] [[ ][ [] ]u)

    // A nested outline in ordinal space (offsets abstract — text offsets
    // or page indices, the math is the same):
    //   h1@0  h2@100  h3@200  h3@300  h2@400  h1@500  h2@600
    private let nestedHeadings = [
        ReadHeading(offset: 0, level: 1),
        ReadHeading(offset: 100, level: 2),
        ReadHeading(offset: 200, level: 3),
        ReadHeading(offset: 300, level: 3),
        ReadHeading(offset: 400, level: 2),
        ReadHeading(offset: 500, level: 1),
        ReadHeading(offset: 600, level: 2),
    ]

    func testHeadingForwardFindsNextHeading() {
        XCTAssertEqual(ReadNavigator.headingTarget(headings: nestedHeadings, from: 150,
                                                   direction: .forward), 200)
        // From exactly ON a heading, forward is strictly past it
        XCTAssertEqual(ReadNavigator.headingTarget(headings: nestedHeadings, from: 200,
                                                   direction: .forward), 300)
    }

    func testHeadingBackFindsPreviousHeading() {
        XCTAssertEqual(ReadNavigator.headingTarget(headings: nestedHeadings, from: 150,
                                                   direction: .back), 100)
        // From exactly ON a heading, back travels — no restart treadmill
        XCTAssertEqual(ReadNavigator.headingTarget(headings: nestedHeadings, from: 100,
                                                   direction: .back), 0)
    }

    func testHeadingDoesNotWrap() {
        XCTAssertNil(ReadNavigator.headingTarget(headings: nestedHeadings, from: 650,
                                                 direction: .forward))
        XCTAssertNil(ReadNavigator.headingTarget(headings: nestedHeadings, from: 0,
                                                 direction: .back))
        XCTAssertNil(ReadNavigator.headingTarget(headings: [], from: 50,
                                                 direction: .forward))
    }

    func testSiblingSkipsDeeperLevels() {
        // In h2@100's body: next sibling hops over both h3s to h2@400
        XCTAssertEqual(ReadNavigator.siblingHeadingTarget(headings: nestedHeadings,
                                                          from: 120, direction: .forward), 400)
        // And back from h2@400's body over the h3s to h2@100
        XCTAssertEqual(ReadNavigator.siblingHeadingTarget(headings: nestedHeadings,
                                                          from: 420, direction: .back), 100)
    }

    func testSiblingAbortsAtParentBoundary() {
        // h2@400's next same-level heading is h2@600, but h1@500 sits
        // between them — siblings share a parent, so this is nil
        XCTAssertNil(ReadNavigator.siblingHeadingTarget(headings: nestedHeadings,
                                                        from: 450, direction: .forward))
    }

    func testSiblingBeforeAnyHeadingIsNil() {
        let late = [ReadHeading(offset: 10, level: 2), ReadHeading(offset: 20, level: 2)]
        XCTAssertNil(ReadNavigator.siblingHeadingTarget(headings: late, from: 5,
                                                        direction: .forward))
    }

    func testFlatDocumentSiblingEqualsNext() {
        let flat = [ReadHeading(offset: 10, level: 2),
                    ReadHeading(offset: 20, level: 2),
                    ReadHeading(offset: 30, level: 2)]
        XCTAssertEqual(ReadNavigator.siblingHeadingTarget(headings: flat, from: 12,
                                                          direction: .forward), 20)
        XCTAssertEqual(ReadNavigator.siblingHeadingTarget(headings: flat, from: 25,
                                                          direction: .back), 10)
    }

    func testParentClimbsOneLevel() {
        // In h3@200's body → its h2; in h2@400's body → the opening h1
        XCTAssertEqual(ReadNavigator.parentHeadingTarget(headings: nestedHeadings,
                                                         from: 250), 100)
        XCTAssertEqual(ReadNavigator.parentHeadingTarget(headings: nestedHeadings,
                                                         from: 450), 0)
    }

    func testParentAtTopLevelIsNil() {
        XCTAssertNil(ReadNavigator.parentHeadingTarget(headings: nestedHeadings, from: 50))
        // Before any heading there is nothing to climb from
        let late = [ReadHeading(offset: 10, level: 1)]
        XCTAssertNil(ReadNavigator.parentHeadingTarget(headings: late, from: 5))
    }

    func testLineStartOffsetsInvertNewlineCounting() {
        // "a\nb\n\nc": lines start at 0, 2, 4 (the empty line), 5 —
        // blank lines COUNT, unlike the content-run line motions
        XCTAssertEqual(ReadNavigator.lineStartOffsets(in: "a\nb\n\nc"), [0, 2, 4, 5])
        XCTAssertEqual(ReadNavigator.lineStartOffsets(in: ""), [0])
    }

    func testHeadingOffsetsClampAndDedup() {
        let starts = [0, 2, 4, 5]
        // Line 99 clamps to the last line; two entries collapsing onto
        // the same offset keep the first
        XCTAssertEqual(
            ReadNavigator.headingOffsets(lines: [(line: 1, level: 2), (line: 99, level: 3)],
                                         lineStarts: starts),
            [ReadHeading(offset: 2, level: 2), ReadHeading(offset: 5, level: 3)])
        XCTAssertEqual(
            ReadNavigator.headingOffsets(lines: [(line: 3, level: 2), (line: 99, level: 3)],
                                         lineStarts: starts),
            [ReadHeading(offset: 5, level: 2)])
        XCTAssertEqual(ReadNavigator.headingOffsets(lines: [(line: 0, level: 1)],
                                                    lineStarts: []), [])
    }

    func testSpellOutPlainAndPhonetic() {
        XCTAssertEqual(SpeechEngine.spellOut("Cat 9", nato: false),
                       "capital c, a, t, space, 9")
        XCTAssertEqual(SpeechEngine.spellOut("Cab", nato: true),
                       "capital Charlie, Alpha, Bravo")
    }

    // MARK: - PagedText

    func testPagedTextOffsets() {
        // "One." at 0; "\n\n" join; "Two two." at 6; "Three." at 16
        let paged = PagedText(pages: ["One.", "Two two.", "Three."])
        XCTAssertEqual(paged.pageStarts, [0, 6, 16])
        XCTAssertEqual(paged.pageCount, 3)
        XCTAssertEqual(paged.pageIndex(at: 0), 0)
        XCTAssertEqual(paged.pageIndex(at: 5), 0)   // in the join → preceding
        XCTAssertEqual(paged.pageIndex(at: 6), 1)
        XCTAssertEqual(paged.pageIndex(at: 99), 2)  // past the end → last
    }

    func testPagedTextEmptyPagesAndUTF16() {
        let paged = PagedText(pages: ["🦉 owl", "", "next"])
        // "🦉" is 2 UTF-16 units: "🦉 owl" = 6 units, join = 2 → page 2 at 8
        XCTAssertEqual(paged.pageStarts, [0, 8, 10])
        XCTAssertEqual(paged.pageIndex(at: 9), 1)
    }

    func testPreviewPageTitleParsing() {
        XCTAssertEqual(PagedText.previewPage(
            fromTitle: "report.pdf — Page 3 of 12"), 3)
        XCTAssertEqual(PagedText.previewPage(
            fromTitle: "book.pdf — Page 12 of 300 — Edited"), 12)
        XCTAssertNil(PagedText.previewPage(fromTitle: "report.pdf"))
        XCTAssertNil(PagedText.previewPage(fromTitle: "Page of nothing"))
    }
}

final class PagedWindowTests: XCTestCase {

    private func paged(pageSize: Int, count: Int) -> PagedText {
        PagedText(pages: (0..<count).map { i in
            String(repeating: "p\(i) ", count: pageSize / 4)
        })
    }

    func testWindowRespectsBudget() {
        let doc = paged(pageSize: 10_000, count: 50)   // ~500k chars total
        let (first, window) = doc.window(startingAt: 0)
        XCTAssertEqual(first, 0)
        XCTAssertLessThanOrEqual((window.text as NSString).length, 45_000)
        XCTAssertGreaterThan(window.pageCount, 1)
        XCTAssertLessThan(window.pageCount, doc.pageCount)
    }

    func testWindowFromLatePageReachesIt() {
        let doc = paged(pageSize: 10_000, count: 50)
        let (first, window) = doc.window(startingAt: 40)
        XCTAssertEqual(first, 40)
        XCTAssertTrue(window.text.hasPrefix("p40 "))
    }

    func testWindowAlwaysHasAtLeastOnePage() {
        // A single page larger than the budget still loads whole
        let doc = PagedText(pages: [String(repeating: "x", count: 60_000)])
        let (first, window) = doc.window(startingAt: 0)
        XCTAssertEqual(first, 0)
        XCTAssertEqual(window.pageCount, 1)
    }

    func testWindowClampsOutOfRange() {
        let doc = paged(pageSize: 100, count: 5)
        XCTAssertEqual(doc.window(startingAt: 99).firstPage, 4)
        XCTAssertEqual(doc.window(startingAt: -3).firstPage, 0)
    }

    func testSmallDocumentWindowIsWholeDocument() {
        let doc = paged(pageSize: 500, count: 10)
        let (first, window) = doc.window(startingAt: 0)
        XCTAssertEqual(first, 0)
        XCTAssertEqual(window.pageCount, 10)
        XCTAssertEqual(window.text, doc.text)
    }
}
