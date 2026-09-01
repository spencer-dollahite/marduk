import XCTest
@testable import marduk

/// Re-entry reads WHERE NEWSBOAT IS off its title line. The signatures
/// are compiled from the effective config, so both newsboat's stock
/// formats and this user's own (long, truncatable) ones must resolve to
/// the right layer — a wrong layer is exactly the desync being fixed.
final class NewsboatScreenTests: XCTestCase {

    private let stock = NewsboatScreen.signatures(configText: nil)

    /// The user's real config (marduk-news), verbatim: every title line
    /// replaced, the article list carrying the feed title mid-line.
    private let userConfig = """
        show-keymap-hint no
        feedlist-title-format "MARDUK  j:Down k:Up ENTER:Open R:Read t:Top3 d:Delete y:Yank /:Find C:ReadAll i:Raw ESC:Quit  (%u unread)"
        articlelist-title-format "MARDUK  %T  j:Down k:Up ENTER/R:Read d:Delete y:Yank o:Browser /:Find h:Back"
        itemview-title-format "MARDUK reading  SPACE:Pause b/w:Word (/):Sentence /:Search hold-ESC:Stop"
        """
    private lazy var user = NewsboatScreen.signatures(configText: userConfig)

    // MARK: - Stock formats

    func testStockFeedListIsRecognised() {
        let screen = """
            newsboat 2.38.0 - Your feeds (12 unread, 44 total)
               1 N   (3/40) BBC World
               2     (0/12) KSL
            """
        XCTAssertEqual(NewsboatScreen.detect(screen: screen, signatures: stock),
                       .feeds)
    }

    func testStockArticleListCapturesTheFeedTitle() {
        let screen = """
            newsboat 2.38.0 - Articles in feed 'BBC World' (3 unread, 40 total) - https://feeds.bbci.co.uk/news/world/rss.xml
               1 N  Sep 01   Headline one
            """
        XCTAssertEqual(NewsboatScreen.detect(screen: screen, signatures: stock),
                       .articles(feedTitle: "BBC World"))
    }

    func testStockPagerAndSideDialogs() {
        XCTAssertEqual(NewsboatScreen.detect(
            screen: "newsboat 2.38.0 - Article 'Some headline' (3 unread, 40 total)",
            signatures: stock), .pager)
        XCTAssertEqual(NewsboatScreen.detect(
            screen: "newsboat 2.38.0 - Help", signatures: stock), .other("help"))
        XCTAssertEqual(NewsboatScreen.detect(
            screen: "newsboat 2.38.0 - URLs", signatures: stock), .other("urlview"))
        XCTAssertEqual(NewsboatScreen.detect(
            screen: "newsboat 2.38.0 - Search results for 'rust' (1 unread, 5 total)",
            signatures: stock), .other("searchresult"))
        XCTAssertEqual(NewsboatScreen.detect(
            screen: "newsboat 2.38.0 - Dialogs", signatures: stock),
            .other("dialogs"))
    }

    func testAnArticleTitledLikeAFeedListDoesNotFoolThePager() {
        // The pager line contains the feed list's literals inside %T;
        // the pager signature still scores higher on its own line.
        let screen = "newsboat 2.38.0 - Article 'x - Your feeds (1 unread, 2 total)' (3 unread, 40 total)"
        XCTAssertEqual(NewsboatScreen.detect(screen: screen, signatures: stock),
                       .pager)
    }

    // MARK: - The user's formats

    func testUserFeedList() {
        let screen = """
            MARDUK  j:Down k:Up ENTER:Open R:Read t:Top3 d:Delete y:Yank /:Find C:ReadAll i:Raw ESC:Quit  (7 unread)
               1 N   (3/40) BBC World
            """
        XCTAssertEqual(NewsboatScreen.detect(screen: screen, signatures: user),
                       .feeds)
    }

    func testUserArticleListCapturesTheFeedTitle() {
        let screen = """
            MARDUK  Breaking Points  j:Down k:Up ENTER/R:Read d:Delete y:Yank o:Browser /:Find h:Back
               1 N  Sep 01   Episode 1526
            """
        XCTAssertEqual(NewsboatScreen.detect(screen: screen, signatures: user),
                       .articles(feedTitle: "Breaking Points"))
    }

    func testUserPager() {
        XCTAssertEqual(NewsboatScreen.detect(
            screen: "MARDUK reading  SPACE:Pause b/w:Word (/):Sentence /:Search hold-ESC:Stop",
            signatures: user), .pager)
    }

    func testTruncatedTitleLinesStillResolve() {
        // An 80-column window cuts these formats short. The feed list
        // keeps its layer; the article list keeps its layer AND its feed
        // title, read up to where the cut literal begins.
        let feeds = "MARDUK  j:Down k:Up ENTER:Open R:Read t:Top3 d:Delete y:Yank /:Find C:ReadAll i"
        XCTAssertEqual(NewsboatScreen.detect(screen: feeds, signatures: user),
                       .feeds)
        let articles = "MARDUK  Breaking Points  j:Down k:Up ENTER/R:Read d:Delete y:Yank o:Browser /:Fi"
        XCTAssertEqual(NewsboatScreen.detect(screen: articles, signatures: user),
                       .articles(feedTitle: "Breaking Points"))
    }

    func testUserFeedListIsNotMistakenForAnArticleList() {
        // Both start with "MARDUK  " — the article signature earns 8
        // chars on the feed line, the feed signature earns the lot.
        let line = "MARDUK  j:Down k:Up ENTER:Open R:Read t:Top3 d:Delete y:Yank /:Find C:ReadAll i:Raw ESC:Quit  (0 unread)"
        XCTAssertEqual(NewsboatScreen.detect(screen: line, signatures: user),
                       .feeds)
    }

    // MARK: - Screens that are not newsboat

    func testAShellPromptIsUnknown() {
        let screen = """
            Last login: Tue Sep  1 09:12:03 on ttys002
            spencer@mac ~ % ls
            Desktop  Documents
            spencer@mac ~ %
            """
        XCTAssertNil(NewsboatScreen.detect(screen: screen, signatures: stock))
        XCTAssertNil(NewsboatScreen.detect(screen: screen, signatures: user))
        XCTAssertNil(NewsboatScreen.detect(screen: "", signatures: stock))
    }

    func testTheTitleWinsOverRowsThatQuoteIt() {
        // A row can carry a stray " - " or an "MARDUK" — the title line
        // scores highest and decides.
        let screen = """
            newsboat 2.38.0 - Articles in feed 'Tech' (1 unread, 9 total) - https://t/rss
               1    Sep 01   Your feeds (2 unread, 3 total) - a headline about newsboat
               2 N  Sep 01   MARDUK  j:Down is not a title
            """
        XCTAssertEqual(NewsboatScreen.detect(screen: screen, signatures: stock),
                       .articles(feedTitle: "Tech"))
    }

    // MARK: - Config → formats

    func testTitleFormatsOverlayTheStockTable() {
        let formats = NewsboatScreen.titleFormats(configText: userConfig)
        XCTAssertEqual(formats["itemview"],
                       "MARDUK reading  SPACE:Pause b/w:Word (/):Sentence /:Search hold-ESC:Stop")
        XCTAssertEqual(formats["help"], NewsboatScreen.stockFormats["help"])
        XCTAssertEqual(NewsboatScreen.titleFormats(configText: nil),
                       NewsboatScreen.stockFormats)
    }

    func testConfigParsingIgnoresCommentsUnknownKeysAndHonorsEscapes() {
        let config = """
            # feedlist-title-format "commented out"
            bogus-title-format "not a dialog"
            help-title-format "Say \\"help\\" \\\\ here"
            urlview-title-format bare value to the end
            dialogs-title-format ""
            """
        let formats = NewsboatScreen.titleFormats(configText: config)
        XCTAssertEqual(formats["feedlist"], NewsboatScreen.stockFormats["feedlist"])
        XCTAssertNil(formats["bogus"])
        XCTAssertEqual(formats["help"], "Say \"help\" \\ here")
        XCTAssertEqual(formats["urlview"], "bare value to the end")
        // An empty override is no override
        XCTAssertEqual(formats["dialogs"], NewsboatScreen.stockFormats["dialogs"])
    }

    // MARK: - Format → signature

    func testCompileFollowsNewsboatsGrammar() {
        let sig = NewsboatScreen.compile(
            key: "articlelist",
            format: "100%% %N%>x%=5c[%-20T]%?F? filter '%F'&? end")
        XCTAssertEqual(sig.tokens, [
            .literal("100% "), .wild, .wild, .wild, .literal("["),
            .feedTitle, .literal("]"), .wild, .literal(" end"),
        ])
        // Only the ARTICLE list's %T is the feed title
        XCTAssertEqual(NewsboatScreen.compile(key: "itemview", format: "%T").tokens,
                       [.wild])
    }

    func testAmbiguousLinesAreIgnored() {
        // Two signatures with identical literals tie on every line —
        // nothing can be concluded from such a line.
        let twins = [
            NewsboatScreen.compile(key: "feedlist", format: "%N - Same words"),
            NewsboatScreen.compile(key: "itemview", format: "%N - Same words"),
        ]
        XCTAssertNil(NewsboatScreen.detect(screen: "x - Same words",
                                           signatures: twins))
    }

    // MARK: - Climbing

    func testOnlyPagerAndSideDialogsAreClimbed() {
        // q on the feed list quits newsboat; q on an unknown screen could
        // be anything — neither may ever be posted by the climb.
        XCTAssertTrue(NewsboatScreen.climbsOut(of: .pager))
        XCTAssertTrue(NewsboatScreen.climbsOut(of: .other("help")))
        XCTAssertFalse(NewsboatScreen.climbsOut(of: .feeds))
        XCTAssertFalse(NewsboatScreen.climbsOut(of: .articles(feedTitle: "x")))
        XCTAssertFalse(NewsboatScreen.climbsOut(of: nil))
    }

    func testLogNameNeverCarriesTheFeedTitle() {
        XCTAssertEqual(NewsboatScreen.logName(.articles(feedTitle: "Private Feed")),
                       "article list")
        XCTAssertEqual(NewsboatScreen.logName(nil), "unknown")
    }
}
