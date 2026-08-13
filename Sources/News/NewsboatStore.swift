import Foundation
import SQLite3

/// Where a newsboat installation lives: the binary, the urls file, the
/// cache database, and (only when the user scoped one) a config file.
/// All four resolve independently — newsboat itself mixes dotdir and XDG
/// locations freely, and Marduk's `news` config block can point every one
/// of them somewhere private (`newsboat -u/-c/-C`), giving Marduk its own
/// newsboat instance without ever touching a stock setup.
struct NewsboatEnvironment: Equatable {
    var binaryPath: String?   // nil = newsboat isn't installed
    var urlsFile: String?     // nil = no urls file anywhere we know
    var cacheFile: String     // where the cache IS or WILL BE (may not exist yet)
    var configFile: String?   // only when overridden — stock runs use newsboat's own
}

enum NewsboatLocator {
    /// Brew and stock locations, in preference order. A custom
    /// `news.command` whose first token is an absolute path bypasses this.
    static let binaryCandidates = [
        "/opt/homebrew/bin/newsboat",
        "/usr/local/bin/newsboat",
        "/opt/local/bin/newsboat",
    ]

    /// The Marduk-scoped newsboat home: a directory the user (typically)
    /// clones from their own PRIVATE git repo. When it holds an `urls`
    /// file it wins over the stock newsboat locations, its `config` rides
    /// -C when present, and its cache.db lives beside them (gitignored) —
    /// a complete second newsboat instance that never touches a stock
    /// setup, with the feed list managed wherever the repo is.
    static func mardukNewsDir(home: String) -> String {
        home + "/.config/marduk/news"
    }

    /// Resolve the environment. `fileExists` is injected so the logic is
    /// testable without a Mac's real filesystem. Precedence for each path:
    /// explicit `news` config override → the Marduk-scoped news dir →
    /// newsboat's own locations (dotdir, then XDG).
    static func resolve(command: String?,
                        urlsOverride: String?, cacheOverride: String?,
                        configOverride: String?,
                        home: String,
                        fileExists: (String) -> Bool) -> NewsboatEnvironment {
        let firstToken = (command ?? "newsboat -r")
            .split(separator: " ").first.map(String.init) ?? "newsboat"
        let binary: String?
        if firstToken.contains("/") {
            binary = fileExists(firstToken) ? firstToken : nil
        } else {
            binary = binaryCandidates.first(where: fileExists)
        }

        let scopedDir = mardukNewsDir(home: home)
        let scoped = fileExists(scopedDir + "/urls")

        let urls: String?
        if let override = urlsOverride {
            let path = expand(override, home: home)
            urls = fileExists(path) ? path : nil
        } else if scoped {
            urls = scopedDir + "/urls"
        } else {
            // newsboat's own search order: dotdir first, then XDG
            let dotdir = home + "/.newsboat/urls"
            let xdg = home + "/.config/newsboat/urls"
            urls = [dotdir, xdg].first(where: fileExists)
        }

        let cache: String
        if let override = cacheOverride {
            cache = expand(override, home: home)
        } else if scoped {
            cache = scopedDir + "/cache.db"
        } else {
            let dotdir = home + "/.newsboat/cache.db"
            let xdg = home + "/.local/share/newsboat/cache.db"
            cache = fileExists(dotdir) ? dotdir
                : fileExists(xdg) ? xdg
                : dotdir  // a fresh install writes the dotdir default
        }

        let config: String?
        if let override = configOverride {
            config = expand(override, home: home)
        } else if scoped, fileExists(scopedDir + "/config") {
            config = scopedDir + "/config"
        } else {
            // The stock config newsboat would read anyway — resolved so
            // the mirror can parse display-affecting options out of it
            // (passing it back via -C is a no-op for newsboat itself)
            let dotdir = home + "/.newsboat/config"
            let xdg = home + "/.config/newsboat/config"
            config = [dotdir, xdg].first(where: fileExists)
        }

        return NewsboatEnvironment(
            binaryPath: binary,
            urlsFile: urls,
            cacheFile: cache,
            configFile: config)
    }

    static func expand(_ path: String, home: String) -> String {
        path.hasPrefix("~/") ? home + path.dropFirst(1) : path
    }

    /// newsboat's goto-first-unread (DEFAULT YES): entering a feed puts
    /// the TUI cursor on the first unread article, not the top row. The
    /// mirror must start where newsboat starts, so it parses the option
    /// out of the effective config — last uncommented setting wins,
    /// missing file or option means the default.
    static func gotoFirstUnread(configText: String?) -> Bool {
        guard let configText else { return true }
        var result = true
        for raw in configText.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            let tokens = NewsboatURLsParser.tokenize(line)
            guard tokens.count >= 2, tokens[0] == "goto-first-unread" else { continue }
            result = !["no", "false", "0"].contains(tokens[1].lowercased())
        }
        return result
    }

    /// Does this command already carry newsboat's refresh-on-start flag?
    /// Short flags may be bundled (`-rq`), so any single-dash token
    /// containing an `r` counts; long options are matched whole. Values
    /// (paths, log levels) never start with a dash, so they can't fake a
    /// match.
    static func hasRefreshFlag(_ command: String) -> Bool {
        for token in command.split(separator: " ").dropFirst() {
            if token == "--refresh-on-start" { return true }
            if token.hasPrefix("--") { continue }
            if token.hasPrefix("-"),
               token.dropFirst().contains(where: { $0 == "r" }) { return true }
        }
        return false
    }

    /// The full shell command Terminal runs. Every open reloads every feed
    /// (user ruling), which on a fresh launch is newsboat's own
    /// refresh-on-start — so a custom `news.command` that omits `-r` gets
    /// it APPENDED rather than quietly opening yesterday's cache. Scoped
    /// paths ride newsboat's own -u/-c/-C flags so the mirror reads
    /// exactly the files newsboat writes.
    static func launchCommand(_ env: NewsboatEnvironment,
                              command: String?) -> String {
        let base = command ?? "newsboat -r"
        var parts = [hasRefreshFlag(base) ? base : base + " -r"]
        if let urls = env.urlsFile { parts.append("-u \(shellQuote(urls))") }
        parts.append("-c \(shellQuote(env.cacheFile))")
        if let config = env.configFile { parts.append("-C \(shellQuote(config))") }
        return parts.joined(separator: " ")
    }

    /// Single-quote a path for /bin/sh (Terminal's do script).
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Is a newsboat already running against this cache? newsboat writes
    /// its PID into cache.db.lock; a live PID means attach, a stale or
    /// absent lock means launch.
    static func runningPID(cachePath: String,
                           read: (String) -> String? = {
                               try? String(contentsOfFile: $0, encoding: .utf8)
                           },
                           isAlive: (Int32) -> Bool = { kill($0, 0) == 0 }) -> Int32? {
        guard let text = read(cachePath + ".lock"),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0, isAlive(pid) else { return nil }
        return pid
    }
}

// MARK: - urls file

/// One line of newsboat's urls file. Tags follow the URL, whitespace-
/// separated, double-quotable; "~Title" overrides the display name and
/// "!" hides the feed from the feed list (query-feed fodder). Query
/// feeds are `query:<name>:<filter>` and DO appear in the list.
struct NewsboatURLEntry: Equatable {
    var url: String
    var titleOverride: String?
    var hidden: Bool
    var isQuery: Bool
    var queryName: String?
}

enum NewsboatURLsParser {
    static func parse(_ text: String) -> [NewsboatURLEntry] {
        text.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            var tokens = tokenize(trimmed)
            guard let url = tokens.first else { return nil }
            tokens.removeFirst()
            let title = tokens.first(where: { $0.hasPrefix("~") })
                .map { String($0.dropFirst()) }
            let hidden = tokens.contains("!")
            let isQuery = url.hasPrefix("query:")
            var queryName: String?
            if isQuery {
                let parts = url.split(separator: ":", maxSplits: 2,
                                      omittingEmptySubsequences: false)
                if parts.count >= 2 { queryName = String(parts[1]) }
            }
            return NewsboatURLEntry(url: url, titleOverride: title,
                                    hidden: hidden, isQuery: isQuery,
                                    queryName: queryName)
        }
    }

    /// Whitespace tokenizer honoring double quotes ("~My title").
    static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for ch in line {
            if ch == "\"" {
                quoted.toggle()
            } else if ch == " " || ch == "\t", !quoted {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

// MARK: - cache.db

/// Read-only view of newsboat's SQLite cache. Every query matches what
/// newsboat itself displays with DEFAULT settings: feeds in urls-file
/// order (feed-sort-order none), articles newest-first (the shipped
/// article-sort-order — newsboat's own cache load orders
/// `pubDate DESC, id DESC`, and its stable sort preserves that for
/// ties). A user who re-sorts newsboat in its config desyncs the
/// mirror — documented limit. Failures degrade to empty results,
/// never crashes; content is user data and is NEVER logged.
final class NewsboatDB {
    private var db: OpaquePointer?

    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle else {
            fputs("[news] cache.db open failed\n", stderr)
            sqlite3_close(handle)
            return nil
        }
        // newsboat may be mid-reload; wait briefly instead of erroring
        sqlite3_busy_timeout(handle, 250)
        db = handle
    }

    deinit { sqlite3_close(db) }

    /// rssurl → fetched feed title.
    func feedTitles() -> [String: String] {
        var titles: [String: String] = [:]
        query("SELECT rssurl, title FROM rss_feed") { stmt in
            if let url = column(stmt, 0), let title = column(stmt, 1) {
                titles[url] = title
            }
        }
        return titles
    }

    /// feedurl → unread article count.
    func unreadCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        query("""
            SELECT feedurl, COUNT(*) FROM rss_item
            WHERE unread = 1 AND deleted = 0 GROUP BY feedurl
            """) { stmt in
            if let url = column(stmt, 0) {
                counts[url] = Int(sqlite3_column_int64(stmt, 1))
            }
        }
        return counts
    }

    /// Mirror caps the list so a pathological feed can't wedge gg/G
    /// arrow-posting; newsboat shows everything, so past the cap the
    /// mirror refuses bottom-jumps honestly (buzz) rather than desync.
    static let articleLimit = 2000

    /// The feed's articles in newsboat's default display order.
    func articles(feedURL: String) -> [NewsSession.Article] {
        var items: [NewsSession.Article] = []
        query("""
            SELECT id, title, url, unread FROM rss_item
            WHERE feedurl = ?1 AND deleted = 0
            ORDER BY pubDate DESC, id DESC LIMIT \(Self.articleLimit)
            """, bind: feedURL) { stmt in
            items.append(NewsSession.Article(
                id: sqlite3_column_int64(stmt, 0),
                title: column(stmt, 1) ?? "Untitled",
                url: column(stmt, 2) ?? "",
                unread: sqlite3_column_int64(stmt, 3) == 1))
        }
        return items
    }

    /// The newest unread headlines across ALL feeds — triage fodder.
    /// Feed URL rides along so the caller can resolve display titles
    /// and jump targets.
    func unreadItems(limit: Int) -> [(id: Int64, title: String, feedURL: String)] {
        var items: [(Int64, String, String)] = []
        query("""
            SELECT id, title, feedurl FROM rss_item
            WHERE unread = 1 AND deleted = 0
            ORDER BY pubDate DESC, id DESC LIMIT \(max(1, limit))
            """) { stmt in
            items.append((sqlite3_column_int64(stmt, 0),
                          column(stmt, 1) ?? "Untitled",
                          column(stmt, 2) ?? ""))
        }
        return items
    }

    /// Which feed an article belongs to — the triage jump's first hop.
    func articleFeedURL(id: Int64) -> String? {
        var feedURL: String?
        query("SELECT feedurl FROM rss_item WHERE id = \(id)") { stmt in
            feedURL = column(stmt, 0)
        }
        return feedURL
    }

    /// The article body (HTML, as the feed delivered it).
    func content(id: Int64) -> String? {
        var content: String?
        query("SELECT content FROM rss_item WHERE id = \(id)") { stmt in
            content = column(stmt, 0)
        }
        return content
    }

    /// What a reload actually brought in — the ONLY observable Marduk has.
    /// newsboat reports per-feed fetch results in its own TUI and nowhere
    /// else, so "are we getting fresh items" can only be answered by
    /// watching the cache before and after.
    ///
    /// Counts and timestamps ONLY, never titles or feed URLs: the daemon
    /// log is designed to be pasted into public issues (`:log copy`,
    /// `:bug`), and a subscription list is the user's business. A stale
    /// COUNT still says "something is eating items"; naming the feeds is
    /// what sqlite3 on the cache is for.
    struct CacheSnapshot: Equatable {
        var items = 0
        var unread = 0
        /// pubDate <= 0: items whose feed shipped no parseable date. Worth
        /// counting because date-based `ignore-article` rules silently
        /// discard exactly these.
        var undated = 0
        var feedsWithItems = 0
        var newest: Int64 = 0       // max pubDate; 0 = nothing dated
    }

    func snapshot() -> CacheSnapshot {
        var snap = CacheSnapshot()
        query("""
            SELECT COUNT(*), SUM(unread = 1), SUM(pubDate <= 0),
                   COUNT(DISTINCT feedurl), MAX(pubDate)
            FROM rss_item WHERE deleted = 0
            """) { stmt in
            snap.items = Int(sqlite3_column_int64(stmt, 0))
            snap.unread = Int(sqlite3_column_int64(stmt, 1))
            snap.undated = Int(sqlite3_column_int64(stmt, 2))
            snap.feedsWithItems = Int(sqlite3_column_int64(stmt, 3))
            snap.newest = sqlite3_column_int64(stmt, 4)
        }
        return snap
    }

    /// How many subscribed feeds have brought in NOTHING since `cutoff`,
    /// feeds with no items at all included. The single most diagnostic
    /// number in the report: a few is normal (quiet blogs), most of them
    /// means a filter or the fetch is eating items.
    func feedsStale(since cutoff: Int64, subscribed: Int) -> Int {
        var fresh = 0
        query("""
            SELECT COUNT(*) FROM (
                SELECT feedurl FROM rss_item WHERE deleted = 0
                GROUP BY feedurl HAVING MAX(pubDate) >= \(cutoff))
            """) { stmt in
            fresh = Int(sqlite3_column_int64(stmt, 0))
        }
        return max(0, subscribed - fresh)
    }

    /// One log line describing the cache. Pure so the wording is testable.
    static func cacheReport(_ snap: CacheSnapshot, subscribed: Int,
                            staleFeeds: Int, now: Int64) -> String {
        var parts = ["\(snap.items) items", "\(snap.unread) unread",
                     "\(snap.feedsWithItems)/\(subscribed) feeds have items"]
        parts.append(snap.newest > 0
            ? "newest \(age(seconds: now - snap.newest)) old"
            : "nothing dated")
        if staleFeeds > 0 { parts.append("\(staleFeeds) feeds stale") }
        if snap.undated > 0 { parts.append("\(snap.undated) undated") }
        return parts.joined(separator: ", ")
    }

    /// What a reload changed, or why it looks like it changed nothing.
    static func reloadReport(before: CacheSnapshot, after: CacheSnapshot,
                             elapsed: Int) -> String {
        let gained = after.items - before.items
        let head = gained > 0
            ? "+\(gained) items in \(elapsed)s"
            : "NO new items in \(elapsed)s"
        let unread = after.unread - before.unread
        return head + ", unread \(unread >= 0 ? "+" : "")\(unread)"
    }

    /// Coarse age words — a log reader wants the order of magnitude, and
    /// a precise timestamp would date the user's reading session.
    static func age(seconds: Int64) -> String {
        if seconds <= 0 { return "0m" }     // clock skew / future pubDate
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }

    private func query(_ sql: String, bind text: String? = nil,
                       row: (OpaquePointer) -> Void) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            fputs("[news] query prepare failed\n", stderr)
            return
        }
        defer { sqlite3_finalize(stmt) }
        if let text {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, text, -1, transient)
        }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    private func column(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }
}
