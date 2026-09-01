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

    /// Where newsboat's cursor lands after a delete+purge — read out of
    /// newsboat's SOURCE (itemlistformaction.cpp, 2026-08-27), not
    /// guessed, after two shipped guesses drifted in the field:
    /// OP_DELETE advances the cursor one row EXCEPT on the last row
    /// (`if (itempos < visible_items.size() - 1)`), and OP_PURGE_DELETED
    /// remembers the selected row BY GUID and restores onto it — so a
    /// non-last delete lands on the following item at the same index,
    /// while a LAST-row delete stores the doomed row's own guid and the
    /// restore, finding nothing, falls to `set_position(0)`: THE TOP.
    enum DeleteLanding: Equatable {
        case next  // same index — the item that followed
        case top   // newsboat jumped to row 0; the mirror must follow
    }

    /// Remove the current article from the mirror, landing where NEWSBOAT
    /// lands. Nil = nothing to delete.
    mutating func deleteCurrentArticle() -> DeleteLanding? {
        guard level == .articles,
              articles.indices.contains(articleIndex) else { return nil }
        let wasLast = articleIndex == articles.count - 1
        articles.remove(at: articleIndex)
        guard wasLast else { return .next }
        articleIndex = 0
        // An emptied list has no top to land on — the reader backs out.
        return articles.isEmpty ? .next : .top
    }

    /// Mark the current article read in the mirror (newsboat marks its own
    /// copy when the pager opens; the db row may only flush on quit).
    mutating func markCurrentArticleRead() {
        guard articles.indices.contains(articleIndex) else { return }
        articles[articleIndex].unread = false
    }

    /// WHAT MARDUK HAS ALREADY CAUSED, held against cache.db's staleness.
    ///
    /// newsboat keeps its live state in MEMORY and flushes cache.db when it
    /// QUITS. Marduk re-reads that file mid-session — on every feed entry,
    /// every reclaim, every count refresh — and treats it as truth, which
    /// silently discards everything Marduk itself just did. Read an article
    /// and back out: newsboat's copy is read, the file's copy is not, so
    /// re-entering the feed computes goto-first-unread against a row that
    /// newsboat has already moved past. The mirror lands one row above the
    /// TUI, and every j/k after that is off by one. Delete two and it is
    /// off by three, because a `deleted = 0` row comes back into a list
    /// newsboat is no longer showing.
    ///
    /// So the disk is not the truth — the disk PLUS what we caused is. This
    /// is the cursor-ledger pattern: we cannot read newsboat's memory, but
    /// we can observe our own actions, which is the half that went missing.
    ///
    /// Cleared exactly when the file becomes authoritative again: newsboat
    /// quitting (it flushes on the way out) or being replaced by a fresh
    /// launch. It deliberately SURVIVES news mode closing while newsboat
    /// keeps running, because that is precisely when the two disagree.
    struct Ledger: Equatable {
        private(set) var read: Set<Int64> = []
        private(set) var deleted: Set<Int64> = []
        /// Per feed, how many of ITS unread items we have accounted for —
        /// the spoken unread counts come from the same stale file.
        private(set) var unreadDelta: [String: Int] = [:]

        mutating func markRead(_ article: Article, feed: String) {
            guard !deleted.contains(article.id) else { return }
            guard read.insert(article.id).inserted else { return }
            if article.unread { unreadDelta[feed, default: 0] += 1 }
        }

        mutating func markDeleted(_ article: Article, feed: String) {
            guard deleted.insert(article.id).inserted else { return }
            // Reading it already spent the count; deleting it must not
            // spend it twice.
            if article.unread, !read.contains(article.id) {
                unreadDelta[feed, default: 0] += 1
            }
        }

        func applied(to list: [Article]) -> [Article] {
            guard !read.isEmpty || !deleted.isEmpty else { return list }
            return list.compactMap { article in
                guard !deleted.contains(article.id) else { return nil }
                guard read.contains(article.id) else { return article }
                var seen = article
                seen.unread = false
                return seen
            }
        }

        func applied(to counts: [String: Int]) -> [String: Int] {
            guard !unreadDelta.isEmpty else { return counts }
            var adjusted = counts
            for (feed, spent) in unreadDelta {
                guard let current = adjusted[feed] else { continue }
                adjusted[feed] = max(0, current - spent)
            }
            return adjusted
        }

        mutating func forget() {
            read = []
            deleted = []
            unreadDelta = [:]
        }
    }

    // MARK: - Resuming where newsboat is (re-entry, reclaim)

    /// The feed a title names, in the mirror's list: an exact match first,
    /// else the ONE feed whose title starts with it — newsboat truncates
    /// its title line to the terminal width, so a long feed name can
    /// arrive cut short. Two feeds sharing the prefix is ambiguous: nil,
    /// and the reader climbs back to the feed list rather than guess.
    static func feedRow(titled title: String, in feeds: [Feed]) -> Int? {
        let wanted = title.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        if let exact = feeds.firstIndex(where: { $0.title == wanted }) {
            return exact
        }
        let prefixed = feeds.indices.filter { feeds[$0].title.hasPrefix(wanted) }
        return prefixed.count == 1 ? prefixed[0] : nil
    }

    /// Where a resumed list lands: the retained row if its item is still
    /// in the fresh list (a reload may have shifted it), else the top.
    static func resumeIndex(retainedID: Int64?, in list: [Article]) -> Int {
        guard let retainedID,
              let index = list.firstIndex(where: { $0.id == retainedID })
        else { return 0 }
        return index
    }

    /// Re-entry restores the row by posting Home and then this many Down
    /// arrows — an ABSOLUTE position, which is why a cursor the user moved
    /// by hand comes back into step. Capped: a run of hundreds of arrows
    /// into a TUI is a stall, not a resume, and past the cap the mirror
    /// lands on the top and says so.
    static let resumeRowCap = 300

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
