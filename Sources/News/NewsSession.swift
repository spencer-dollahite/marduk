import Foundation

/// A semantic key inside NEWS mode — the tap translates raw keycodes to
/// these and the daemon's NewsReader gives them meaning. Pure data, so the
/// tap never knows what a feed is and the reader never sees a keycode.
enum NewsCommand: Equatable {
    case move(Int)      // signed count: +down / -up (j/k, arrows, 3j)
    case top            // gg
    case bottom         // G
    case open           // Return / l — drill in
    case back           // h / q — up a level (q at the feed list quits newsboat)
    case read           // r / R — read the article through the reading machinery
    case openInBrowser  // o — newsboat's own binding, mirrored
    case copyLink       // y — yank the article's (or feed's) URL, vim style
    case rawControl     // i pressed — the key bar shows the raw-mode text
    case markAllRead    // C — newsboat's mark-all-feeds-read, mirrored
    case deleteArticle  // d (or dd — pair window swallowed); posts newsboat's D
    case reclaim        // held Escape out of raw-control INSERT — resync
    case search(String, ReadDirection)  // "/" forward, "?" back — a JUMP to
                                        // the next matching title (the mirror
                                        // can't narrow newsboat's list)
    case searchRepeat   // "." — vim's n by the read-mode precedent (news n = exit)
    case triage         // t — local-LLM top-3 + dedup over the unread headlines
    case exit           // Escape / n — leave NEWS mode (the tap already stood down)
}

/// The spoken mirror of newsboat's TUI: which list is showing and which
/// row is selected. Marduk posts the same movements to newsboat that it
/// applies here, so the voice and the screen stay in step. Pure state —
/// no AX, no SQLite, no key posting — hence fully unit-tested.
struct NewsSession: Equatable {
    struct Feed: Equatable {
        var title: String
        var url: String
        var isQuery: Bool  // newsboat query feed — a virtual feed the
                           // mirror can list but not open (its articles
                           // come from a filter expression, not a feedurl)
    }

    struct Article: Equatable {
        var id: Int64      // rss_item rowid — content is fetched on demand
        var title: String
        var url: String
        var unread: Bool
    }

    enum Level: Equatable { case feeds, articles }

    var level: Level = .feeds
    var feeds: [Feed] = []
    var articles: [Article] = []
    var feedIndex = 0
    var articleIndex = 0

    var currentFeed: Feed? {
        feeds.indices.contains(feedIndex) ? feeds[feedIndex] : nil
    }

    var currentArticle: Article? {
        articles.indices.contains(articleIndex) ? articles[articleIndex] : nil
    }

    private var count: Int { level == .feeds ? feeds.count : articles.count }

    private var index: Int {
        get { level == .feeds ? feedIndex : articleIndex }
        set {
            if level == .feeds { feedIndex = newValue } else { articleIndex = newValue }
        }
    }

    /// Move the selection by a signed count, clamped to the list. Returns
    /// the ACTUAL signed steps taken — the caller posts exactly that many
    /// arrow keys to newsboat, so the mirror can never outrun the TUI.
    /// 0 means the edge (or an empty list): buzz, post nothing.
    mutating func move(_ delta: Int) -> Int {
        guard count > 0 else { return 0 }
        let target = min(max(index + delta, 0), count - 1)
        let steps = target - index
        index = target
        return steps
    }

    /// gg — jump to the first row. Same contract as move.
    mutating func jumpTop() -> Int { move(-count) }

    /// G — jump to the last row. Same contract as move.
    mutating func jumpBottom() -> Int { move(count) }

    /// Enter a feed's article list. `startAt` mirrors where newsboat put
    /// ITS cursor — the top row, or the first unread article under the
    /// default goto-first-unread (the reader computes which).
    mutating func enterArticles(_ list: [Article], startAt: Int = 0) {
        articles = list
        articleIndex = list.isEmpty ? 0 : min(max(startAt, 0), list.count - 1)
        level = .articles
    }

    /// The row goto-first-unread lands on: the first unread scanning down
    /// from the top, else the top itself (newsboat leaves the cursor
    /// there when everything is read).
    static func firstUnreadIndex(_ list: [Article]) -> Int {
        list.firstIndex(where: { $0.unread }) ?? 0
    }

    /// Back out to the feed list. The feed selection is wherever it was.
    mutating func backToFeeds() {
        articles = []
        articleIndex = 0
        level = .feeds
    }

    /// Remove the current article from the mirror (dd → newsboat's D
    /// filters it out of its list immediately; the cursor lands on the
    /// next row, which is the same index). False = nothing to delete.
    mutating func deleteCurrentArticle() -> Bool {
        guard level == .articles,
              articles.indices.contains(articleIndex) else { return false }
        articles.remove(at: articleIndex)
        if articleIndex >= articles.count, articleIndex > 0 { articleIndex -= 1 }
        return true
    }

    /// Mark the current article read in the mirror (newsboat marks its own
    /// copy when the pager opens; the db row may only flush on quit).
    mutating func markCurrentArticleRead() {
        guard articles.indices.contains(articleIndex) else { return }
        articles[articleIndex].unread = false
    }

    /// The next title matching `query` from `from` (exclusive), smartcase
    /// (an all-lowercase query matches case-insensitively), NO WRAP —
    /// audio gives no wrap cue, the read-search rule. Pure, tested.
    static func searchTarget(titles: [String], from: Int, query: String,
                             direction: ReadDirection) -> Int? {
        let smart = query == query.lowercased()
        func matches(_ title: String) -> Bool {
            smart ? title.lowercased().contains(query) : title.contains(query)
        }
        let range: StrideTo<Int> = direction == .forward
            ? stride(from: from + 1, to: titles.count, by: 1)
            : stride(from: from - 1, to: -1, by: -1)
        for index in range where titles.indices.contains(index) {
            if matches(titles[index]) { return index }
        }
        return nil
    }

    // MARK: - Spoken lines (minimal verbosity — the founding rule)

    /// A feed row: the title, with the unread count only when there is one.
    static func feedLine(title: String, unread: Int, isQuery: Bool) -> String {
        if isQuery { return "\(title), search feed" }
        return unread > 0 ? "\(title), \(unread) unread" : title
    }

    /// An article row: the title, flagged only while new.
    static func articleLine(title: String, unread: Bool) -> String {
        unread ? "\(title), new" : title
    }
}
