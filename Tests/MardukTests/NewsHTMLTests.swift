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

    // MARK: - Destination links (feeds that ship no <link>)

    /// The real shape of a premium podcast's show notes: the episode video
    /// first, then a pile of promo links. Document order alone would work
    /// here by luck — the video preference is what makes it a rule.
    private static let showNotes = """
        Ryan and Emily discuss the elections. <br><br>YouTube: \
        <a href="https://www.youtube.com/watch?v=AiXEkEkQebc">\
        https://www.youtube.com/watch?v=AiXEkEkQebc</a> <br><br>Spotify: \
        <a href="https://open.spotify.com/show/033kFesz">Spotify</a><br>\
        Sign Up: <a href="https://breakingpoints.supercast.com/">trial</a>
        """

    func testDestinationPrefersTheVideoOverPromoLinks() {
        XCTAssertEqual(NewsHTML.destination(inBody: Self.showNotes),
                       "https://www.youtube.com/watch?v=AiXEkEkQebc")
    }

    func testDestinationPrefersVideoEvenWhenItIsNotFirst() {
        let notes = """
            Sponsor: <a href="https://sponsor.example/deal">deal</a><br>
            Watch: <a href="https://youtu.be/AiXEkEkQebc">video</a>
            """
        XCTAssertEqual(NewsHTML.destination(inBody: notes),
                       "https://youtu.be/AiXEkEkQebc")
    }

    func testDestinationFallsBackToTheFirstLinkWithNoVideo() {
        let notes = """
            <a href="https://example.com/a">a</a>
            <a href="https://example.com/b">b</a>
            """
        XCTAssertEqual(NewsHTML.destination(inBody: notes),
                       "https://example.com/a")
    }

    func testDestinationFindsBareURLsAndDecodesEntities() {
        XCTAssertEqual(
            NewsHTML.destination(inBody: "Watch https://youtu.be/abc123 now"),
            "https://youtu.be/abc123")
        XCTAssertEqual(
            NewsHTML.destination(
                inBody: "<a href=\"https://ex.com/a?x=1&amp;y=2\">a</a>"),
            "https://ex.com/a?x=1&y=2")
    }

    func testDestinationIsNilWhenThereIsNothingToOpen() {
        XCTAssertNil(NewsHTML.destination(inBody: ""))
        XCTAssertNil(NewsHTML.destination(inBody: "<p>No links at all.</p>"))
        // Non-http schemes are not destinations
        XCTAssertNil(NewsHTML.destination(
            inBody: "<a href=\"mailto:x@example.com\">mail</a>"))
    }

    func testVideoHostMatchingIsBySuffixNotSubstring() {
        XCTAssertTrue(NewsHTML.isVideo("https://www.youtube.com/watch?v=a"))
        XCTAssertTrue(NewsHTML.isVideo("https://m.youtube.com/watch?v=a"))
        XCTAssertTrue(NewsHTML.isVideo("https://youtu.be/a"))
        // A lookalike host must never pass for the real one
        XCTAssertFalse(NewsHTML.isVideo("https://youtube.com.evil.test/watch"))
        XCTAssertFalse(NewsHTML.isVideo("https://notyoutube.com/watch"))
        XCTAssertFalse(NewsHTML.isVideo("https://example.com/youtube.com"))
    }

    func testLinksKeepDocumentOrderAndDeduplicate() {
        // The anchor and its visible text are the same URL — one entry
        let links = NewsHTML.links(in: Self.showNotes)
        XCTAssertEqual(links.first, "https://www.youtube.com/watch?v=AiXEkEkQebc")
        XCTAssertEqual(links.count, Set(links).count)
        XCTAssertEqual(links.count, 3)
    }
}
