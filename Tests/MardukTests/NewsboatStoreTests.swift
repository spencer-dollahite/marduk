import XCTest
import SQLite3
@testable import marduk

/// The newsboat side of NEWS mode: locating an installation, parsing the
/// urls file, composing the launch command, and reading cache.db in
/// newsboat's own display order. The DB tests run against a real SQLite
/// fixture built with the same schema columns the queries touch.
final class NewsboatStoreTests: XCTestCase {

    // MARK: - urls file

    func testUrlsParserSkipsCommentsAndBlanksAndReadsTags() {
        let text = """
            # my feeds

            https://a.example/feed.xml
            https://b.example/rss "~Better Name" tech
            https://c.example/rss "!"
            "query:Starred:age between 0:7" important
            """
        let entries = NewsboatURLsParser.parse(text)
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[0].url, "https://a.example/feed.xml")
        XCTAssertNil(entries[0].titleOverride)
        XCTAssertFalse(entries[0].hidden)
        XCTAssertEqual(entries[1].titleOverride, "Better Name")
        XCTAssertTrue(entries[2].hidden)
        XCTAssertTrue(entries[3].isQuery)
        XCTAssertEqual(entries[3].queryName, "Starred")
    }

    func testTokenizerHonorsDoubleQuotes() {
        XCTAssertEqual(NewsboatURLsParser.tokenize("a \"b c\" d"),
                       ["a", "b c", "d"])
        XCTAssertEqual(NewsboatURLsParser.tokenize("url \"~My Title\""),
                       ["url", "~My Title"])
    }

    // MARK: - locator

    func testResolvePrefersDotdirThenXDGAndHonorsOverrides() {
        let existing: Set<String> = [
            "/opt/homebrew/bin/newsboat",
            "/home/u/.config/newsboat/urls",
            "/home/u/.local/share/newsboat/cache.db",
        ]
        let env = NewsboatLocator.resolve(
            command: nil, urlsOverride: nil, cacheOverride: nil,
            configOverride: nil, home: "/home/u",
            fileExists: { existing.contains($0) })
        XCTAssertEqual(env.binaryPath, "/opt/homebrew/bin/newsboat")
        // Dotdir urls absent — XDG found
        XCTAssertEqual(env.urlsFile, "/home/u/.config/newsboat/urls")
        XCTAssertEqual(env.cacheFile, "/home/u/.local/share/newsboat/cache.db")

        let scoped = NewsboatLocator.resolve(
            command: nil, urlsOverride: "~/mine/urls",
            cacheOverride: "~/mine/cache.db", configOverride: "~/mine/config",
            home: "/home/u",
            fileExists: { existing.contains($0) || $0 == "/home/u/mine/urls" })
        XCTAssertEqual(scoped.urlsFile, "/home/u/mine/urls")
        XCTAssertEqual(scoped.cacheFile, "/home/u/mine/cache.db")
        XCTAssertEqual(scoped.configFile, "/home/u/mine/config")
    }

    func testMardukScopedNewsDirWinsOverStockLocations() {
        let existing: Set<String> = [
            "/opt/homebrew/bin/newsboat",
            "/home/u/.config/marduk/news/urls",
            "/home/u/.config/marduk/news/config",
            "/home/u/.newsboat/urls",          // stock setup ALSO present
            "/home/u/.newsboat/cache.db",
        ]
        let env = NewsboatLocator.resolve(
            command: nil, urlsOverride: nil, cacheOverride: nil,
            configOverride: nil, home: "/home/u",
            fileExists: { existing.contains($0) })
        // The private-repo clone runs as its own instance: its urls, its
        // config, its cache — the stock ~/.newsboat is never touched
        XCTAssertEqual(env.urlsFile, "/home/u/.config/marduk/news/urls")
        XCTAssertEqual(env.cacheFile, "/home/u/.config/marduk/news/cache.db")
        XCTAssertEqual(env.configFile, "/home/u/.config/marduk/news/config")
        // An explicit override still beats the scoped dir
        let overridden = NewsboatLocator.resolve(
            command: nil, urlsOverride: "~/.newsboat/urls", cacheOverride: nil,
            configOverride: nil, home: "/home/u",
            fileExists: { existing.contains($0) })
        XCTAssertEqual(overridden.urlsFile, "/home/u/.newsboat/urls")
    }

    func testResolveMissingBinaryAndAbsoluteCommandPath() {
        let none = NewsboatLocator.resolve(
            command: nil, urlsOverride: nil, cacheOverride: nil,
            configOverride: nil, home: "/home/u", fileExists: { _ in false })
        XCTAssertNil(none.binaryPath)
        // A fresh install defaults the cache to the dotdir path
        XCTAssertEqual(none.cacheFile, "/home/u/.newsboat/cache.db")

        let custom = NewsboatLocator.resolve(
            command: "/weird/place/newsboat -r", urlsOverride: nil,
            cacheOverride: nil, configOverride: nil, home: "/home/u",
            fileExists: { $0 == "/weird/place/newsboat" })
        XCTAssertEqual(custom.binaryPath, "/weird/place/newsboat")
    }

    func testLaunchCommandCarriesScopedPathsQuoted() {
        let env = NewsboatEnvironment(
            binaryPath: "/opt/homebrew/bin/newsboat",
            urlsFile: "/home/u/My Files/urls",
            cacheFile: "/home/u/.newsboat/cache.db",
            configFile: nil)
        let command = NewsboatLocator.launchCommand(env, command: nil)
        XCTAssertEqual(command,
            "newsboat -r -u '/home/u/My Files/urls' -c '/home/u/.newsboat/cache.db'")
        // A custom command keeps its own flags...
        let custom = NewsboatLocator.launchCommand(env, command: "newsboat -r -q")
        XCTAssertTrue(custom.hasPrefix("newsboat -r -q -u "))
        // ...but every open reloads every feed, so a command that forgot
        // the refresh flag gets it rather than opening a stale cache
        let bare = NewsboatLocator.launchCommand(env, command: "newsboat")
        XCTAssertTrue(bare.hasPrefix("newsboat -r -u "))
        let bundled = NewsboatLocator.launchCommand(env, command: "newsboat -qr")
        XCTAssertTrue(bundled.hasPrefix("newsboat -qr -u "))
    }

    func testRefreshFlagDetection() {
        XCTAssertTrue(NewsboatLocator.hasRefreshFlag("newsboat -r"))
        XCTAssertTrue(NewsboatLocator.hasRefreshFlag("newsboat -q -r"))
        XCTAssertTrue(NewsboatLocator.hasRefreshFlag("newsboat -rq"))
        XCTAssertTrue(NewsboatLocator.hasRefreshFlag("newsboat --refresh-on-start"))
        XCTAssertFalse(NewsboatLocator.hasRefreshFlag("newsboat"))
        XCTAssertFalse(NewsboatLocator.hasRefreshFlag("newsboat -q"))
        // The command's own name never counts as a flag, and neither does
        // a VALUE that happens to contain an r
        XCTAssertFalse(NewsboatLocator.hasRefreshFlag("/opt/rr/newsboat"))
        XCTAssertFalse(NewsboatLocator.hasRefreshFlag("newsboat -c /tmp/rss.db"))
        XCTAssertFalse(NewsboatLocator.hasRefreshFlag("newsboat --url-file=/r/urls"))
    }

    func testGotoFirstUnreadParsesTheEffectiveConfig() {
        // Missing config or option → newsboat's default (yes)
        XCTAssertTrue(NewsboatLocator.gotoFirstUnread(configText: nil))
        XCTAssertTrue(NewsboatLocator.gotoFirstUnread(configText: "auto-reload no"))
        XCTAssertFalse(NewsboatLocator.gotoFirstUnread(
            configText: "goto-first-unread no"))
        // Comments don't count; the LAST live setting wins
        XCTAssertTrue(NewsboatLocator.gotoFirstUnread(configText: """
            # goto-first-unread no
            goto-first-unread no
            goto-first-unread yes
            """))
    }

    func testShellQuoteSurvivesApostrophes() {
        XCTAssertEqual(NewsboatLocator.shellQuote("it's here"),
                       "'it'\\''s here'")
    }

    func testRunningPIDRequiresALiveProcess() {
        XCTAssertEqual(
            NewsboatLocator.runningPID(cachePath: "/c",
                                       read: { _ in "1234\n" },
                                       isAlive: { $0 == 1234 }), 1234)
        XCTAssertNil(NewsboatLocator.runningPID(cachePath: "/c",
                                                read: { _ in "1234" },
                                                isAlive: { _ in false }))
        XCTAssertNil(NewsboatLocator.runningPID(cachePath: "/c",
                                                read: { _ in nil },
                                                isAlive: { _ in true }))
        XCTAssertNil(NewsboatLocator.runningPID(cachePath: "/c",
                                                read: { _ in "junk" },
                                                isAlive: { _ in true }))
    }

    // MARK: - cache.db (real SQLite fixture)

    private func makeFixture() throws -> String {
        let path = NSTemporaryDirectory() + "marduk-test-\(UUID().uuidString).db"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
            CREATE TABLE rss_feed (rssurl TEXT PRIMARY KEY, url TEXT, title TEXT);
            CREATE TABLE rss_item (id INTEGER PRIMARY KEY, guid TEXT,
                title TEXT, author TEXT, url TEXT, feedurl TEXT,
                pubDate INTEGER, content TEXT, unread INTEGER,
                deleted INTEGER DEFAULT 0);
            INSERT INTO rss_feed VALUES ('https://f1', 'https://s1', 'Feed One');
            INSERT INTO rss_feed VALUES ('https://f2', 'https://s2', 'Feed Two');
            -- f1: three live articles + one deleted; two unread.
            -- Same pubDate for ids 2 and 3 — newsboat breaks the tie id DESC.
            INSERT INTO rss_item VALUES (1, 'g1', 'Oldest', 'a', 'https://x/1',
                'https://f1', 100, '<p>old</p>', 0, 0);
            INSERT INTO rss_item VALUES (2, 'g2', 'Tied Low', 'a', 'https://x/2',
                'https://f1', 200, '<p>two</p>', 1, 0);
            INSERT INTO rss_item VALUES (3, 'g3', 'Tied High', 'a', 'https://x/3',
                'https://f1', 200, '<p>three</p>', 1, 0);
            INSERT INTO rss_item VALUES (4, 'g4', 'Deleted', 'a', 'https://x/4',
                'https://f1', 300, '<p>gone</p>', 1, 1);
            INSERT INTO rss_item VALUES (5, 'g5', 'Other Feed', 'a', 'https://x/5',
                'https://f2', 400, '<p>other</p>', 1, 0);
            """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        return path
    }

    func testDBReadsTitlesCountsAndNewsboatDisplayOrder() throws {
        let path = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let db = NewsboatDB(path: path) else {
            return XCTFail("fixture db failed to open")
        }
        XCTAssertEqual(db.feedTitles()["https://f1"], "Feed One")
        // Deleted rows never count
        XCTAssertEqual(db.unreadCounts()["https://f1"], 2)
        XCTAssertEqual(db.unreadCounts()["https://f2"], 1)

        let articles = db.articles(feedURL: "https://f1")
        // Newest first, ties broken by id DESC, deleted rows absent —
        // newsboat's own cache-load order, which its stable sort preserves
        XCTAssertEqual(articles.map(\.title), ["Tied High", "Tied Low", "Oldest"])
        XCTAssertEqual(articles.map(\.unread), [true, true, false])
        XCTAssertEqual(db.content(id: articles[0].id), "<p>three</p>")
    }

    func testDBOnAMissingFileIsNilNotACrash() {
        XCTAssertNil(NewsboatDB(path: "/nonexistent/nowhere.db"))
    }
}
