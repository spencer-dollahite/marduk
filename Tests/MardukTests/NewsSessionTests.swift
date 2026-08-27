import XCTest
@testable import marduk

/// The NEWS-mode mirror: selection movement must return EXACTLY the steps
/// the reader will post to newsboat as arrow keys — a mirror that claims
/// more movement than the TUI performs desyncs every later command.
final class NewsSessionTests: XCTestCase {

    private func feeds(_ count: Int) -> [NewsSession.Feed] {
        (0..<count).map {
            NewsSession.Feed(title: "Feed \($0)", url: "https://f/\($0)", isQuery: false)
        }
    }

    private func articles(_ count: Int) -> [NewsSession.Article] {
        (0..<count).map {
            NewsSession.Article(id: Int64($0), title: "Article \($0)",
                                url: "https://a/\($0)", unread: true)
        }
    }

    func testMoveClampsAtTheEdgesAndReportsActualSteps() {
        var session = NewsSession()
        session.feeds = feeds(5)
        XCTAssertEqual(session.move(3), 3)
        XCTAssertEqual(session.feedIndex, 3)
        // Only one row remains below — the mirror must post ONE arrow
        XCTAssertEqual(session.move(5), 1)
        XCTAssertEqual(session.feedIndex, 4)
        // At the bottom: zero steps, caller buzzes, nothing posted
        XCTAssertEqual(session.move(1), 0)
        XCTAssertEqual(session.move(-10), -4)
        XCTAssertEqual(session.feedIndex, 0)
        XCTAssertEqual(session.move(-1), 0)
    }

    func testMoveOnAnEmptyListPostsNothing() {
        var session = NewsSession()
        XCTAssertEqual(session.move(1), 0)
        XCTAssertEqual(session.move(-1), 0)
    }

    func testTopAndBottomJumpByExactDistance() {
        var session = NewsSession()
        session.feeds = feeds(10)
        XCTAssertEqual(session.jumpBottom(), 9)
        XCTAssertEqual(session.feedIndex, 9)
        XCTAssertEqual(session.jumpBottom(), 0)  // already there — buzz
        XCTAssertEqual(session.jumpTop(), -9)
        XCTAssertEqual(session.feedIndex, 0)
        XCTAssertEqual(session.jumpTop(), 0)
    }

    func testEnteringArticlesStartsAtTheTopAndBackKeepsTheFeedRow() {
        var session = NewsSession()
        session.feeds = feeds(5)
        _ = session.move(2)
        session.enterArticles(articles(4))
        XCTAssertEqual(session.level, .articles)
        XCTAssertEqual(session.articleIndex, 0)
        XCTAssertEqual(session.currentArticle?.title, "Article 0")
        _ = session.move(2)
        session.backToFeeds()
        XCTAssertEqual(session.level, .feeds)
        // The feed selection is untouched by the article excursion
        XCTAssertEqual(session.feedIndex, 2)
        // A fresh article list never inherits the old index
        session.enterArticles(articles(2))
        XCTAssertEqual(session.articleIndex, 0)
    }

    func testMovementIsPerLevel() {
        var session = NewsSession()
        session.feeds = feeds(3)
        session.enterArticles(articles(10))
        XCTAssertEqual(session.move(7), 7)   // article list is the live list
        XCTAssertEqual(session.feedIndex, 0) // feed cursor untouched
    }

    func testEnterArticlesMirrorsGotoFirstUnread() {
        // newsboat's default parks the cursor on the first unread row —
        // the mirror computes the same row and starts there
        var list = articles(5)
        list[0].unread = false
        list[1].unread = false
        XCTAssertEqual(NewsSession.firstUnreadIndex(list), 2)
        var session = NewsSession()
        session.feeds = feeds(1)
        session.enterArticles(list, startAt: NewsSession.firstUnreadIndex(list))
        XCTAssertEqual(session.currentArticle?.title, "Article 2")
        // Everything read → the cursor stays at the top
        let allRead = list.map { a -> NewsSession.Article in
            var a = a; a.unread = false; return a
        }
        XCTAssertEqual(NewsSession.firstUnreadIndex(allRead), 0)
        // A wild startAt clamps instead of crashing
        session.enterArticles(list, startAt: 99)
        XCTAssertEqual(session.articleIndex, 4)
    }

    func testDeleteCurrentArticleMirrorsNewsboatsD() {
        var session = NewsSession()
        session.feeds = feeds(1)
        session.enterArticles(articles(3))
        _ = session.move(1)
        // Deleting the middle row lands on the NEXT row (same index)
        XCTAssertTrue(session.deleteCurrentArticle())
        XCTAssertEqual(session.articles.map(\.title), ["Article 0", "Article 2"])
        XCTAssertEqual(session.currentArticle?.title, "Article 2")
        // Deleting the last row steps back instead of falling off
        XCTAssertTrue(session.deleteCurrentArticle())
        XCTAssertEqual(session.currentArticle?.title, "Article 0")
        XCTAssertTrue(session.deleteCurrentArticle())
        XCTAssertFalse(session.deleteCurrentArticle())  // empty — nothing left
        // Feed level never deletes
        session.backToFeeds()
        XCTAssertFalse(session.deleteCurrentArticle())
    }

    func testMarkCurrentArticleRead() {
        var session = NewsSession()
        session.feeds = feeds(1)
        session.enterArticles(articles(2))
        session.markCurrentArticleRead()
        XCTAssertFalse(session.articles[0].unread)
        XCTAssertTrue(session.articles[1].unread)
    }

    func testSearchTargetIsSmartcaseAndNeverWraps() {
        let titles = ["Krebs on Security", "The Hacker News",
                      "Dark Reading", "SANS NewsBites"]
        XCTAssertEqual(NewsSession.searchTarget(
            titles: titles, from: 0, query: "news", direction: .forward), 1)
        // "." repeat from the landing row hunts the NEXT match
        XCTAssertEqual(NewsSession.searchTarget(
            titles: titles, from: 1, query: "news", direction: .forward), 3)
        // No wrap — audio gives no wrap cue
        XCTAssertNil(NewsSession.searchTarget(
            titles: titles, from: 3, query: "news", direction: .forward))
        XCTAssertEqual(NewsSession.searchTarget(
            titles: titles, from: 3, query: "hacker", direction: .back), 1)
        // Capitals make it case-sensitive (smartcase)
        XCTAssertNil(NewsSession.searchTarget(
            titles: titles, from: 0, query: "NEWS", direction: .forward))
        XCTAssertEqual(NewsSession.searchTarget(
            titles: titles, from: 0, query: "News", direction: .forward), 1)
        XCTAssertNil(NewsSession.searchTarget(
            titles: [], from: 0, query: "x", direction: .forward))
    }

    // MARK: - Spoken lines (minimal verbosity)

    func testFeedLineSpeaksUnreadOnlyWhenPresent() {
        XCTAssertEqual(NewsSession.feedLine(title: "Ars", unread: 12, isQuery: false),
                       "Ars, 12 unread")
        XCTAssertEqual(NewsSession.feedLine(title: "Ars", unread: 0, isQuery: false),
                       "Ars")
        XCTAssertEqual(NewsSession.feedLine(title: "Starred", unread: 3, isQuery: true),
                       "Starred, search feed")
    }

    func testArticleLineFlagsOnlyNewItems() {
        XCTAssertEqual(NewsSession.articleLine(title: "Headline", unread: true),
                       "Headline, new")
        XCTAssertEqual(NewsSession.articleLine(title: "Headline", unread: false),
                       "Headline")
    }

    // MARK: - Which Terminal window newsboat is in
    //
    // Field 2026-08-13: every posted key went to whichever Terminal window
    // was front, and `d`'s Shift+D deleted six articles out of a newsboat
    // the user couldn't see. The id in `do script`'s reply is the only
    // handle we get on the right window; a parse that silently returns nil
    // is a mirror that refuses to post, which is the safe failure — a
    // parse that returns the WRONG number aims destructive keys at a
    // stranger's window, so the digits are taken strictly.

    func testWindowIDParsesDoScriptReply() {
        XCTAssertEqual(NewsReader.windowID(
            fromDoScriptReply: "tab 1 of window id 3274\n"), 3274)
        XCTAssertEqual(NewsReader.windowID(
            fromDoScriptReply: "tab 12 of window id 8\n"), 8)
    }

    func testRaiseScriptLooksForTheProcessAndBringsItForward() {
        // Which window newsboat is in is a FACT Terminal can answer —
        // "the front window" is whatever the user was last in, which on
        // the attach path is routinely a shell.
        let script = NewsReader.raiseScript(process: "newsboat")
        XCTAssertTrue(script.contains("contains \"newsboat\""))
        XCTAssertTrue(script.contains("processes of t"))
        XCTAssertTrue(script.contains("activate"))
        XCTAssertTrue(script.contains("set frontmost of window id found to true"))
        // No match must answer with something that parses as "no window",
        // never a number that would aim keys at a stranger's window.
        XCTAssertTrue(script.contains("if found is 0 then return \"\""))
        XCTAssertNil(NewsReader.windowID(fromDoScriptReply: ""))
    }

    func testWindowIDRefusesRepliesWithoutOne() {
        // No reply at all, an error, and a tab specifier with no window —
        // all mean "we don't know", and nil is what makes the caller
        // refuse rather than guess.
        XCTAssertNil(NewsReader.windowID(fromDoScriptReply: ""))
        XCTAssertNil(NewsReader.windowID(
            fromDoScriptReply: "execution error: Terminal got an error"))
        XCTAssertNil(NewsReader.windowID(fromDoScriptReply: "tab 1"))
        XCTAssertNil(NewsReader.windowID(
            fromDoScriptReply: "tab 1 of window id notanumber"))
    }

    // MARK: - The session ledger (cache.db is stale by design)

    private func article(_ id: Int64, unread: Bool) -> NewsSession.Article {
        NewsSession.Article(id: id, title: "Item \(id)",
                            url: "https://example.test/\(id)", unread: unread)
    }

    /// Reading an article then re-entering the feed must not re-offer it as
    /// unread — that off-by-one is what walks the mirror away from the TUI.
    func testReadArticleStaysReadAcrossAFreshQuery() {
        var ledger = NewsSession.Ledger()
        let list = [article(1, unread: true), article(2, unread: true)]
        ledger.markRead(list[0], feed: "f")
        let applied = ledger.applied(to: list)
        XCTAssertEqual(applied.map(\.unread), [false, true])
        XCTAssertEqual(NewsSession.firstUnreadIndex(applied), 1,
                       "goto-first-unread must land where newsboat's cursor "
                       + "is, not on the row it already moved past")
    }

    func testDeletedArticleDoesNotComeBack() {
        var ledger = NewsSession.Ledger()
        let list = [article(1, unread: true), article(2, unread: false)]
        ledger.markDeleted(list[0], feed: "f")
        XCTAssertEqual(ledger.applied(to: list).map(\.id), [2])
    }

    func testUnreadCountsAreAdjustedByWhatWeCaused() {
        var ledger = NewsSession.Ledger()
        ledger.markRead(article(1, unread: true), feed: "f")
        ledger.markDeleted(article(2, unread: true), feed: "f")
        XCTAssertEqual(ledger.applied(to: ["f": 5]), ["f": 3])
    }

    /// Reading THEN deleting the same article spends one unread, not two.
    func testReadThenDeletedCountsOnce() {
        var ledger = NewsSession.Ledger()
        let item = article(1, unread: true)
        ledger.markRead(item, feed: "f")
        ledger.markDeleted(item, feed: "f")
        XCTAssertEqual(ledger.applied(to: ["f": 2]), ["f": 1])
    }

    func testAlreadyReadArticleSpendsNoCount() {
        var ledger = NewsSession.Ledger()
        ledger.markRead(article(1, unread: false), feed: "f")
        XCTAssertEqual(ledger.applied(to: ["f": 4]), ["f": 4])
    }

    func testMarkingTheSameArticleTwiceIsIdempotent() {
        var ledger = NewsSession.Ledger()
        let item = article(1, unread: true)
        ledger.markRead(item, feed: "f")
        ledger.markRead(item, feed: "f")
        XCTAssertEqual(ledger.applied(to: ["f": 3]), ["f": 2])
    }

    func testCountsNeverGoNegative() {
        var ledger = NewsSession.Ledger()
        ledger.markRead(article(1, unread: true), feed: "f")
        ledger.markRead(article(2, unread: true), feed: "f")
        XCTAssertEqual(ledger.applied(to: ["f": 1]), ["f": 0])
    }

    /// A fresh newsboat loads from cache.db, so the two agree again and
    /// everything held against the old process must go.
    func testForgetClearsEverything() {
        var ledger = NewsSession.Ledger()
        ledger.markRead(article(1, unread: true), feed: "f")
        ledger.markDeleted(article(2, unread: true), feed: "f")
        ledger.forget()
        XCTAssertEqual(ledger, NewsSession.Ledger())
    }

    func testEmptyLedgerIsAPassThrough() {
        let ledger = NewsSession.Ledger()
        let list = [article(1, unread: true), article(2, unread: false)]
        XCTAssertEqual(ledger.applied(to: list).map(\.id), [1, 2])
        XCTAssertEqual(ledger.applied(to: ["f": 7]), ["f": 7])
    }

    func testCloseScriptNamesExactlyOneWindow() {
        XCTAssertEqual(NewsReader.closeScript(id: 3274),
                       "tell application \"Terminal\" to close window id 3274")
    }
}
