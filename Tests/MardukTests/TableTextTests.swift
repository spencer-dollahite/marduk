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
