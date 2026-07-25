import XCTest
@testable import marduk

/// Regression net for the large-content incidents: a 9.1M-char Terminal
/// scrollback froze the main thread (input cap), Terminal answered
/// RangeForPosition with garbage at that size (pointer validation), and
/// whole-document paged processing made late PDF pages unreachable
/// (windowing). Regular-size content must stay byte-identical; large
/// content must stay bounded and navigable.
final class LargeContentTests: XCTestCase {

    // MARK: - Pointer offset validation

    func testPointerOffsetInsideVisibleRangePasses() {
        let visible = NSRange(location: 9_000_000, length: 4_000)
        XCTAssertEqual(KeyboardMonitor.validatedPointerOffset(9_002_000,
                                                              visible: visible),
                       9_002_000)
        // Boundaries inclusive
        XCTAssertNotNil(KeyboardMonitor.validatedPointerOffset(9_000_000,
                                                               visible: visible))
        XCTAssertNotNil(KeyboardMonitor.validatedPointerOffset(9_004_000,
                                                               visible: visible))
    }

    func testGarbagePointerOffsetRejected() {
        // The field case: offset ~2k while the visible window sat at ~9.1M
        let visible = NSRange(location: 9_120_000, length: 3_000)
        XCTAssertNil(KeyboardMonitor.validatedPointerOffset(2_107, visible: visible))
        XCTAssertNil(KeyboardMonitor.validatedPointerOffset(9_200_000,
                                                            visible: visible))
    }

    func testNoVisibleRangeTrustsTheOffset() {
        XCTAssertEqual(KeyboardMonitor.validatedPointerOffset(1234, visible: nil), 1234)
        XCTAssertEqual(KeyboardMonitor.validatedPointerOffset(
            1234, visible: NSRange(location: 0, length: 0)), 1234)
    }

    // MARK: - Deliberate caret vs prompt caret

    // R's start priority puts facts before guesses: an insertion point the
    // user placed beats the row estimate (a clamped vertical fraction that
    // answers even when the pointer is nowhere near the text), while a
    // prompt caret pinned to the end of a buffer claims nothing and lets
    // the pointer carry the read.

    func testInteriorCaretIsDeliberate() {
        let doc = "First line of the document.\nSecond line.\nThird line." as NSString
        XCTAssertEqual(KeyboardMonitor.deliberateCaret(28, in: doc), 28)
    }

    func testPromptCaretAtTheEndClaimsNothing() {
        // Terminal: the caret rides the prompt at the end of the scrollback
        let buffer = "…lots of scrollback\nuser@mac ~ % " as NSString
        XCTAssertNil(KeyboardMonitor.deliberateCaret(buffer.length, in: buffer))
        // Trailing newline / spaces after it are still "nothing after"
        let trailing = "output line\n\n   \n" as NSString
        XCTAssertNil(KeyboardMonitor.deliberateCaret(11, in: trailing))
    }

    func testZeroCaretClaimsNothing() {
        // Indistinguishable from an app that never answered the attribute
        let doc = "Some document text." as NSString
        XCTAssertNil(KeyboardMonitor.deliberateCaret(0, in: doc))
    }

    func testCaretLookaheadIsBounded() {
        // Main-thread work beside the event tap: answering "is there
        // content after the caret" must not walk a 9M-char scrollback
        let huge = (String(repeating: " ", count: 9_000_000) + "prompt") as NSString
        let start = Date()
        XCTAssertNil(KeyboardMonitor.deliberateCaret(1, in: huge, lookahead: 4_096))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    // MARK: - Preprocessor: regular content untouched, large content bounded

    func testContentUnderCapPassesThroughWhole() {
        let text = String(repeating: "sentence here. ", count: 3_000)  // 45k
        let out = SpeechPreprocessor.process(text, settings: .default)
        XCTAssertTrue(out.hasSuffix("sentence here."))
        XCTAssertGreaterThan(out.utf16.count, 40_000)
    }

    func testContentOverCapKeepsThePrefix() {
        let text = String(repeating: "alpha ", count: 20_000)  // 120k
        let out = SpeechPreprocessor.process(text, settings: .default)
        XCTAssertTrue(out.hasPrefix("alpha alpha"))
        XCTAssertLessThanOrEqual(out.utf16.count, SpeechPreprocessor.maxInputLength)
    }

    // MARK: - Navigator at scale: correct AND bounded

    func testMotionsOnLargeTextStayFastAndCorrect() {
        let paragraph = String(repeating: "One sentence. Two sentence. ", count: 50)
            + "\n\n"
        let text = String(repeating: paragraph, count: 40)  // ~57k chars
        let ns = text as NSString
        let start = Date()
        // A motion from deep in the text — containing-unit semantics hold
        let mid = ns.length / 2
        let back = ReadNavigator.target(in: text, from: mid,
                                        unit: .sentence, direction: .back)
        XCTAssertLessThan(back, mid)
        let fwd = ReadNavigator.target(in: text, from: mid,
                                       unit: .paragraph, direction: .forward)
        XCTAssertGreaterThan(fwd, mid)
        let hit = ReadNavigator.findChar(in: text, from: 0,
                                         char: "T", direction: .forward)
        XCTAssertNotNil(hit)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0,
                          "navigation must stay interactive on capped-size text")
    }

    func testSearchOnLargeTextFindsLateTarget() {
        var text = String(repeating: "filler words here. ", count: 3_000)
        text += "the needle sentence."
        let target = ReadNavigator.searchTarget(in: text, from: 0,
                                                query: "needle",
                                                direction: .forward)
        XCTAssertNotNil(target)
    }

    // MARK: - Paged windows: global navigation math

    func testWindowPagesMatchFullDocumentPages() {
        let doc = PagedText(pages: (0..<60).map { "page \($0) " +
            String(repeating: "content ", count: 1_200) })  // ~10k/page
        let (first, window) = doc.window(startingAt: 37)
        XCTAssertEqual(first, 37)
        XCTAssertEqual(window.pages.first, doc.pages[37])
        // Global page arithmetic: local index + window origin
        let localOffset = window.pageStarts[1] + 5   // inside window page 2
        XCTAssertEqual(first + window.pageIndex(at: localOffset), 38)
    }

    func testEveryPageOfALargeDocumentIsReachable() {
        let doc = PagedText(pages: (0..<200).map { i in
            String(repeating: "p\(i) ", count: 2_000)  // ~8k chars/page
        })
        for target in [0, 57, 123, 199] {
            let (first, window) = doc.window(startingAt: target)
            XCTAssertEqual(first, target)
            XCTAssertTrue(window.text.hasPrefix("p\(target) "),
                          "page \(target) must be reachable at a window start")
        }
    }

    // MARK: - Windowed long reads: the 9M-char field case, whole and navigable

    func testNineMillionCharDocChunksBoundedAndReachable() {
        let line = "scrollback line with real content 0123456789\n"  // 45 chars
        let text = String(repeating: line, count: 200_000)  // 9M chars
        let ns = text as NSString
        let deepStart = (line as NSString).length * 120_000  // a line start, ~5.4M in

        let started = Date()
        let (paged, startPage) = PagedText.chunking(text, from: deepStart)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10.0,
                          "chunking the field-incident size must stay interactive")

        XCTAssertEqual(paged.pageStarts[startPage - 1], deepStart,
                       "the start page begins exactly at the caret")
        let expectedPages = ns.length / PagedText.syntheticPageSize
        XCTAssertGreaterThan(paged.pageCount, expectedPages / 2)
        XCTAssertLessThan(paged.pageCount, expectedPages * 2)

        // First, caret, and last pages all reachable at window starts
        for target in [0, startPage - 1, paged.pageCount - 1] {
            let (first, window) = paged.window(startingAt: target)
            XCTAssertEqual(first, target)
            XCTAssertLessThanOrEqual((window.text as NSString).length,
                                     PagedText.windowBudget)
        }
    }

    // MARK: - Cap ordering: the plain/paged threshold invariant

    func testWindowBudgetSitsBelowBothCaps() {
        // "Fits one window → plain read" is safe only while a window can
        // never trip the preprocessor: the paged threshold must sit below
        // the input cap AND the output cap (verbalizer expansion margin).
        XCTAssertLessThan(PagedText.windowBudget, SpeechPreprocessor.maxInputLength)
        XCTAssertLessThan(PagedText.windowBudget, SpeechPreprocessor.maxSpokenLength)
    }

    func testExceedsWindowThreshold() {
        XCTAssertFalse(PagedText.exceedsWindow(0))
        XCTAssertFalse(PagedText.exceedsWindow(PagedText.windowBudget))
        XCTAssertTrue(PagedText.exceedsWindow(PagedText.windowBudget + 1))
    }
}
