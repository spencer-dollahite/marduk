import XCTest
@testable import marduk

/// TableText is the pure half of the embedded-table rung (field
/// 2026-07-29: Pages read the body and went silent at the table, because
/// the table is a separate AXTable subtree the single-value harvest
/// never visits). The AX walk needs hardware; the composition and merge
/// rules do not.
final class TableTextTests: XCTestCase {

    // MARK: compose

    func testComposeJoinsCellsAndRows() {
        let text = TableText.compose(rows: [["Name", "Age"], ["Ada", "36"]])
        XCTAssertEqual(text, "Name, Age\nAda, 36")
    }

    func testComposeDropsEmptyCellsAndRows() {
        let text = TableText.compose(rows: [["", "  "], ["Ada", "", "36"], []])
        XCTAssertEqual(text, "Ada, 36")
    }

    func testComposeTrimsCellWhitespace() {
        let text = TableText.compose(rows: [["  Ada \n", "\t36"]])
        XCTAssertEqual(text, "Ada, 36")
    }

    func testComposeEmptyTableIsEmpty() {
        XCTAssertEqual(TableText.compose(rows: []), "")
        XCTAssertEqual(TableText.compose(rows: [[""], ["  "]]), "")
    }

    // MARK: span boilerplate

    func testComposeDropsMergedCellSpanChatter() {
        let text = TableText.compose(rows: [
            ["Name", "spans four rows", "Age"],
            ["Spans 2 columns and 3 rows", "Ada", "36"],
        ])
        XCTAssertEqual(text, "Name, Age\nAda, 36")
    }

    func testSpanBoilerplateMatchesWholeCellOnly() {
        XCTAssertTrue(TableText.isSpanBoilerplate("spans four rows"))
        XCTAssertTrue(TableText.isSpanBoilerplate("Spans 12 columns"))
        XCTAssertTrue(TableText.isSpanBoilerplate("spans two columns and four rows"))
        XCTAssertTrue(TableText.isSpanBoilerplate(" spans four rows. "))
        XCTAssertFalse(TableText.isSpanBoilerplate("the bridge spans four rivers"))
        XCTAssertFalse(TableText.isSpanBoilerplate("spans"))
        XCTAssertFalse(TableText.isSpanBoilerplate("wingspans 2 meters"))
    }

    /// The chatter also rides INSIDE a cell string — its own line, or a
    /// clause glued after the content by a carrier join. Scrub takes it
    /// out wherever it sits; content and unrelated prose survive.
    func testScrubRemovesEmbeddedSpanChatter() {
        XCTAssertEqual(TableText.scrubSpanChatter("Ada\nspans four rows"), "Ada")
        XCTAssertEqual(TableText.scrubSpanChatter("Ada spans four rows"), "Ada")
        XCTAssertEqual(TableText.scrubSpanChatter("Ada spans 2 columns and 3 rows."),
                       "Ada")
        XCTAssertEqual(TableText.scrubSpanChatter("spans four rows"), "")
        XCTAssertEqual(TableText.scrubSpanChatter("Q3 numbers spans four rows spans two columns"),
                       "Q3 numbers")
        XCTAssertEqual(TableText.scrubSpanChatter("the bridge spans four rivers"),
                       "the bridge spans four rivers")
        XCTAssertEqual(TableText.scrubSpanChatter("wingspans 2 meters"),
                       "wingspans 2 meters")
        XCTAssertEqual(TableText.scrubSpanChatter("Ada\nLovelace"), "Ada\nLovelace")
    }

    // MARK: merged

    func testMergedAppendsAfterBlankLine() {
        let merged = TableText.merged(document: "Body text.",
                                      tables: ["Name, Age\nAda, 36"])
        XCTAssertEqual(merged, "Body text.\n\nName, Age\nAda, 36")
    }

    func testMergedKeepsDocumentPrefixByteIdentical() {
        // Every AX-derived offset indexes the body — the merge must
        // never touch it, only append.
        let document = "  Body with\n\nodd   spacing \n"
        let merged = TableText.merged(document: document, tables: ["cell"])
        XCTAssertTrue(merged.hasPrefix(document))
    }

    func testMergedNoTablesReturnsDocumentUntouched() {
        let document = "Body text.\n"
        XCTAssertEqual(TableText.merged(document: document, tables: []), document)
        XCTAssertEqual(TableText.merged(document: document, tables: ["", "  \n"]),
                       document)
    }

    func testMergedTableOnlyIsJustTheTables() {
        let merged = TableText.merged(document: "", tables: ["a, b", "c, d"])
        XCTAssertEqual(merged, "a, b\n\nc, d")
    }

    func testMergedSeparatesMultipleTablesAsParagraphs() {
        let merged = TableText.merged(document: "Body.",
                                      tables: ["a, b", "c, d"])
        XCTAssertEqual(merged, "Body.\n\na, b\n\nc, d")
    }

    // MARK: totalLength

    func testTotalLengthSumsTables() {
        XCTAssertEqual(TableText.totalLength([]), 0)
        XCTAssertEqual(TableText.totalLength(["abc", "de"]), 5)
    }

    /// The thin floor counts body + tables together: a 14-char title box
    /// beside a big table is a document, not chrome.
    func testThinFloorMathAdmitsTableHeavyDocuments() {
        let title = String(repeating: "t", count: 14)
        let table = String(repeating: "c", count: 500)
        XCTAssertTrue(title.count + TableText.totalLength([table])
                        >= KeyboardMonitor.documentTextFloor)
    }
}
