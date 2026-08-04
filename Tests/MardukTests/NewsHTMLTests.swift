import XCTest
@testable import marduk

/// HTML article bodies become plain text shaped for the reading
/// machinery: paragraph closers make BLANK lines ({/} paragraph motions
/// key on those), line-shaped closers make single newlines (j/k), and
/// everything else strips without ever going silent.
final class NewsHTMLTests: XCTestCase {

    func testPlainTextPassesThrough() {
        XCTAssertEqual(NewsHTML.text(from: "Just words."), "Just words.")
    }

    func testParagraphsBecomeBlankLineBlocks() {
        let html = "<p>First paragraph.</p><p>Second paragraph.</p>"
        XCTAssertEqual(NewsHTML.text(from: html),
                       "First paragraph.\n\nSecond paragraph.")
    }

    func testHeadingsAndDivsAlsoBreakParagraphs() {
        let html = "<h1>Title</h1><div>Body text.</div>"
        XCTAssertEqual(NewsHTML.text(from: html), "Title\n\nBody text.")
    }

    func testLineBreaksAndListItemsBecomeSingleNewlines() {
        let html = "one<br>two<br/>three"
        XCTAssertEqual(NewsHTML.text(from: html), "one\ntwo\nthree")
        let list = "<ul><li>alpha</li><li>beta</li></ul>after"
        XCTAssertEqual(NewsHTML.text(from: list), "alpha\nbeta\n\nafter")
    }

    func testScriptAndStyleContentIsDropped() {
        let html = "<p>Real.</p><script>var x = 'never speak this';</script>"
            + "<style>.a { color: red }</style><p>Also real.</p>"
        XCTAssertEqual(NewsHTML.text(from: html), "Real.\n\nAlso real.")
    }

    func testInlineTagsStripWithoutJoiningWords() {
        let html = "A <a href=\"https://x\">link</a> and <em>emphasis</em>."
        XCTAssertEqual(NewsHTML.text(from: html), "A link and emphasis .")
    }

    func testImagesContributeTheirAltText() {
        let html = "Before <img src=\"x.png\" alt=\"a chart of results\"> after"
        XCTAssertEqual(NewsHTML.text(from: html), "Before a chart of results after")
        let bare = "Before <img src=\"x.png\"> after"
        XCTAssertEqual(NewsHTML.text(from: bare), "Before after")
    }

    func testEntitiesDecodeNamedAndNumeric() {
        XCTAssertEqual(NewsHTML.decodeEntities("Fish &amp; chips &lt;now&gt;"),
                       "Fish & chips <now>")
        XCTAssertEqual(NewsHTML.decodeEntities("caf&#233; &#x41;"), "café A")
        // Unknown named entities stay literal — spoken beats vanished
        XCTAssertEqual(NewsHTML.decodeEntities("&weird;"), "&weird;")
    }

    func testWhitespaceNormalizesAndBlankRunsCapAtOne() {
        let html = "<p>One.</p>\n\n\n\n<p>Two.</p><p></p><p></p><p>Three.</p>"
        XCTAssertEqual(NewsHTML.text(from: html), "One.\n\nTwo.\n\nThree.")
    }

    func testEmptyAndTagOnlyInputComeOutEmpty() {
        XCTAssertEqual(NewsHTML.text(from: ""), "")
        XCTAssertEqual(NewsHTML.text(from: "<p></p><div></div>"), "")
    }
}
