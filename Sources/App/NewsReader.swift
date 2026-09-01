import Foundation
import AppKit

/// The daemon-side brain of NEWS mode (`n`): launches newsboat in
/// Terminal, mirrors its lists from the urls file + cache.db, and speaks
/// the row the TUI's cursor is on. Marduk consumes the navigation keys
/// and posts the equivalent ARROW/Enter/q keystrokes to newsboat (arrows,
/// not letters, so a rebound newsboat still moves the same way), which is
/// what keeps the voice and the screen on the same row. Articles are read
/// from the cache — HTML stripped — through the full reading machinery,
/// so every motion, search, and page key works mid-article.
///
/// Re-entry RESUMES (2026-09-01): `n` against a running newsboat reads
/// its title line off Terminal's screen (`NewsboatScreen`), climbs out
/// of a pager or side dialog with q, and re-locks the row by posting
/// Home plus the retained row's worth of Downs — an absolute position,
/// so the mirror and the TUI agree even when the cursor was moved by
/// hand. Held Escape out of raw control (`reclaim`) does the same.
///
/// Known limits (the Firefox-n "blind toggle" precedent): the mirror
/// assumes newsboat's DEFAULT sort orders — custom sort settings desync
/// it, and a screen that can't be read (AX refused, an unrecognised
/// title format) falls back to assuming the feed list, SPOKEN. All
/// main-thread; the store's SQLite reads are small and read-only.
final class NewsReader {

    // Wired by the daemon at startup
    var announce: (String) -> Void = { _ in }
    var startRead: (String) -> Void = { _ in }
    var isReadActive: () -> Bool = { false }
    var postKeys: (CGKeyCode, Bool, Int) -> Void = { _, _, _ in }
    var setCaptured: (Bool) -> Void = { _ in }
    var frontmostApp: () -> String? = { nil }
    var isEngaged: () -> Bool = { true }  // Ctrl+Option+M state at arm time
    // Marduk's own key bar (newsboat's hint bar is hidden by the managed
    // config — it would list NEWSBOAT's keys, not ours). Text swaps for
    // raw control and article reads.
    var showKeyBar: (String) -> Void = { _ in }
    var hideKeyBar: () -> Void = {}
    // Triage plumbing: announce-with-completion (the 1/2/3 window must
    // not tick while the summary is still being read — the dialog-focus
    // rule) and the generalized one-key question capture.
    var announceThen: (String, @escaping () -> Void) -> Void = { _, done in done() }
    var armChoice: (Set<Character>, @escaping (Character) -> Void) -> Void = { _, _ in }
    var isReadPlaying: () -> Bool = { false }

    static let listKeyBar = " j/k move  ⏎ open  R read  t top3  y yank  "
        + "d delete  / find  . next  C read-all  o browser  i raw  h back  esc quit "
    static let rawKeyBar = " RAW newsboat keys — hold esc: back to Marduk "
    static let readingKeyBar = " reading — space pause  hold esc: stop  "
        + "b/w words  (/) sentences  / search "

    static let terminalBundle = "com.apple.Terminal"
    static let helpLine = "j and k move. Enter opens. Uppercase R reads the "
        + "article. o opens it in the browser. Slash searches titles, "
        + "period repeats. h goes back. Escape leaves."

    private(set) var active = false
    private var entering = false
    private var readInFlight = false
    private var session = NewsSession()
    private var newsConfig: MardukConfig.NewsConfig?
    private var env: NewsboatEnvironment?
    private var db: NewsboatDB?
    private var unread: [String: Int] = [:]
    private var lastCountRefresh = Date.distantPast
    // Guards the delayed reload report: a second open supersedes the first
    private var reloadGeneration = 0
    // Where newsboat parks the article-list cursor on feed entry —
    // parsed from the effective config at arm time
    private var gotoFirstUnread = true
    // Which Terminal WINDOW newsboat is in — see ensureTerminalFront.
    // Captured from `do script`'s reply on the launch path, adopted at arm
    // on the attach path, and nil means "refuse to post", never "any
    // window will do".
    private var terminalWindowID: Int?
    /// The window `do script` created THIS session — the only window
    /// Marduk may ever close (the ownership doctrine: "running" is not
    /// "we started it"). Kept SEPARATE from `terminalWindowID` because
    /// the arm-time raise re-aims that at whatever window is running
    /// newsboat — a user's own instance included — and ownership must
    /// not travel with the re-aim: close only when the aim still equals
    /// the window Marduk launched.
    private var launchedWindowID: Int?
    /// What we have caused that cache.db has not caught up with.
    private var ledger = NewsSession.Ledger()
    /// newsboat's title-line signatures, compiled from the effective
    /// config at load — what `readScreen` matches the screen against.
    private var screenSignatures: [NewsboatScreen.Signature] = []
    /// The mirror as it stood when news mode last closed is kept in
    /// `session` on purpose: re-entry lands the user back on that row.
    private var windowVerified = false
    private var windowCheckedAt = Date.distantPast
    /// How long an arrow may ride a previous window check. Short enough
    /// that a window hop costs at most a glide's worth of arrows (which
    /// are harmless in a shell), long enough that holding j doesn't spawn
    /// an osascript per repeat.
    private static let windowRecheckInterval: TimeInterval = 1.0
    private let windowQueue = DispatchQueue(label: "com.marduk.news.window")
    /// The osascript round trips ride here, OFF the FIFO spine: a parked
    /// windowQueue job waits on work that must not queue behind itself.
    private let scriptQueue = DispatchQueue(label: "com.marduk.news.script")

    func configure(_ config: MardukConfig.NewsConfig?) {
        newsConfig = config
    }

    // MARK: - Entry

    /// Outcome of the feed-list sync that runs before every load. newsboat
    /// reads its urls file exactly ONCE, at startup, so a pull that lands
    /// after the launch is a pull that didn't count — the whole load waits
    /// on this, and `changed` decides whether an already-running newsboat
    /// can be reloaded or has to be restarted.
    private enum FeedRepoSync {
        case notARepo
        case synced(changed: Bool)
        case slow                   // still pulling past the soft deadline
        case failed(reason: String)
    }

    /// The load goes ahead without the pull at the SOFT deadline (news must
    /// never hang behind a flaky network) while the pull runs on to the
    /// HARD one in the background, for the next open.
    private static let softPullDeadline: TimeInterval = 6
    private static let hardPullDeadline: TimeInterval = 25

    func enter() {
        guard !active, !entering else {
            if active { announce("News is already open.") }
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let env = NewsboatLocator.resolve(
            command: newsConfig?.command,
            urlsOverride: newsConfig?.urlsFile,
            cacheOverride: newsConfig?.cacheFile,
            configOverride: newsConfig?.configFile,
            home: home,
            fileExists: { FileManager.default.fileExists(atPath: $0) })
        self.env = env

        guard env.binaryPath != nil else {
            // Point, never auto-install — the user rules their machine
            Earcon.error()
            announce("That key opens a news reader powered by newsboat, "
                + "which isn't installed. In Terminal, run: brew install "
                + "newsboat. Then press n again.")
            return
        }
        guard let urlsPath = env.urlsFile,
              !visibleFeeds(text: fileText(urlsPath)).isEmpty else {
            Earcon.error()
            announce("Newsboat has no feeds yet. Add feed addresses to your "
                + "newsboat urls file, one per line, then press n again.")
            return
        }

        entering = true
        fputs("[news] entering\n", stderr)
        // Acknowledge the gesture up front, before the feed-list pull can
        // make the rest of it slow. A fresh launch reloads every feed
        // (user ruling) and says so; a re-entry lands where the user was
        // and only reloads when that turns out to be the feed list, so it
        // promises nothing it may not do.
        let running = NewsboatLocator.runningPID(cachePath: env.cacheFile) != nil
        announce(running ? "News." : "News. Reloading feeds.")
        // The feed list syncs with its repo BEFORE anything is launched:
        // when the urls file lives in a git clone (the private-repo
        // pattern), newsboat must start against the pulled file, not race
        // it. Failures are spoken and never block the news.
        syncFeedRepo(urlsPath: urlsPath) { [self] sync in
            guard entering else { return }   // closed / toggled off meanwhile
            switch sync {
            case .notARepo, .synced:
                break
            case .slow:
                Earcon.error()
                announce("The feed list is still updating. Opening with the "
                    + "feeds from last time.")
            case .failed(let reason):
                Earcon.error()
                fputs("[news] feed list update failed — \(reason)\n", stderr)
                announce("Couldn't update the feed list. Opening with the "
                    + "feeds from last time.")
            }
            var changed = false
            if case .synced(let didChange) = sync { changed = didChange }
            load(urlsPath: urlsPath, urlsChanged: changed)
        }
    }

    /// Start (or reload) newsboat now that the feed list is settled.
    private func load(urlsPath: String, urlsChanged: Bool) {
        guard let env else { entering = false; return }
        // SNAPSHOT the feed list here rather than re-reading it at arm
        // time: a slow pull landing between the launch and the arm would
        // hand newsboat one list and the mirror another, and every posted
        // arrow would then act on the wrong row.
        let feeds = visibleFeeds(text: fileText(urlsPath))
        screenSignatures = NewsboatScreen.signatures(
            configText: env.configFile.flatMap {
                try? String(contentsOfFile: $0, encoding: .utf8)
            })
        guard !feeds.isEmpty else {
            entering = false
            Earcon.error()
            announce("Newsboat has no feeds yet. Add feed addresses to your "
                + "newsboat urls file, one per line, then press n again.")
            return
        }

        let pid = NewsboatLocator.runningPID(cachePath: env.cacheFile)
        if let pid, urlsChanged {
            // A running newsboat CANNOT grow a feed we just pulled — it
            // read its urls file at startup and reload-all only refetches
            // the feeds it already knows. Reloading anyway would leave the
            // mirror listing feeds the TUI doesn't have, which desyncs
            // every posted arrow. Restart it instead.
            announce("The feed list changed. Restarting the news reader.")
            quitNewsboat(pid: pid) { [self] quit in
                guard entering else { return }
                guard quit else {
                    // Never arm a mirror we know disagrees with the screen
                    entering = false
                    Earcon.error()
                    announce("Couldn't restart the news reader. Quit "
                        + "newsboat, then press n again.")
                    return
                }
                startNewsboat(feeds: feeds, attached: false)
            }
            return
        }
        startNewsboat(feeds: feeds, attached: pid != nil)
    }

    /// A reload runs INSIDE newsboat, which reports its per-feed results in
    /// its own TUI and nowhere else — so Marduk brackets it instead:
    /// snapshot the cache when the reload is requested, again once it has
    /// had time to land, and log the difference. This is what makes "it
    /// isn't grabbing fresh items" answerable from the daemon log alone,
    /// without a sqlite3 session against cache.db.
    private static let reloadReportDelay: TimeInterval = 45

    /// Log a cache snapshot; returns it for the before/after delta.
    @discardableResult
    private func reportCache(feeds: Int, stage: String)
        -> NewsboatDB.CacheSnapshot? {
        guard let path = env?.cacheFile else { return nil }
        guard let store = NewsboatDB(path: path) else {
            fputs("[news] cache \(stage): no readable cache yet\n", stderr)
            return nil
        }
        let now = Int64(Date().timeIntervalSince1970)
        let snap = store.snapshot()
        let stale = store.feedsStale(since: now - 7 * 86_400, subscribed: feeds)
        fputs("[news] cache \(stage) — "
            + NewsboatDB.cacheReport(snap, subscribed: feeds,
                                     staleFeeds: stale, now: now)
            + "\n", stderr)
        return snap
    }

    private func startNewsboat(feeds: [NewsboatURLEntry], attached: Bool) {
        guard let env else { entering = false; return }
        fputs("[news] loading (\(attached ? "attach" : "launch"))"
            + " — \(feeds.count) feeds\n", stderr)
        launchedWindowID = nil
        // A NEW newsboat loads its state from cache.db, so at this instant
        // the file and the TUI agree and everything we recorded about the
        // old one is void. An ATTACH is the opposite: that process still
        // remembers reads the file has never seen, which is exactly what
        // the ledger is holding.
        if !attached { ledger.forget() }
        let baseline = reportCache(feeds: feeds.count, stage: "before reload")
        reloadGeneration += 1
        let generation = reloadGeneration
        let requested = Date()
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.reloadReportDelay) { [self] in
            // A newer open owns the report; this one's numbers are moot
            guard generation == reloadGeneration else { return }
            let after = reportCache(feeds: feeds.count, stage: "after reload")
            guard let baseline, let after else { return }
            fputs("[news] reload — " + NewsboatDB.reloadReport(
                before: baseline, after: after,
                elapsed: Int(Date().timeIntervalSince(requested))) + "\n",
                stderr)
        }
        if attached {
            // Attaching means the window already exists and is very
            // likely BEHIND whatever the user was last doing — Terminal
            // restores the last-front window, not newsboat's (user report
            // 2026-08-13: "newsboat did not hold itself in the front… I
            // did not actually switch away from it"). Find newsboat's own
            // window, raise it, and only then look at it: the screen read
            // and every key that follows are checked against that window.
            raiseNewsboatWindow { [self] in
                guard entering else { return }
                guard terminalWindowID != nil else {
                    // Already spoken by the raise — nothing to aim at
                    entering = false
                    return
                }
                locateNewsboat(climbsLeft: 3) { [self] layer in
                    guard entering else { return }
                    arm(feeds: feeds, retriesLeft: 2, how: .resume(layer))
                }
            }
            return
        }
        launchInTerminal(NewsboatLocator.launchCommand(env,
                                                       command: newsConfig?.command))
        // Arm once the TUI can take keys — before that, a posted arrow
        // would land in the shell prompt.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [self] in
            arm(feeds: feeds, retriesLeft: 2, how: .launch)
        }
    }

    /// SIGTERM an attached newsboat and wait for it to actually go, so the
    /// pulled feed list can be loaded by a fresh instance. SQLite's journal
    /// makes an interrupted newsboat safe for the cache, and the stale
    /// cache.db.lock it may leave behind is PID-checked by the next start.
    private func quitNewsboat(pid: Int32, completion: @escaping (Bool) -> Void) {
        fputs("[news] restarting newsboat for a changed feed list\n", stderr)
        kill(pid, SIGTERM)
        waitForExit(pid: pid, triesLeft: 12, completion: completion)
    }

    private func waitForExit(pid: Int32, triesLeft: Int,
                             completion: @escaping (Bool) -> Void) {
        guard kill(pid, 0) == 0 else { completion(true); return }
        guard triesLeft > 0 else {
            fputs("[news] newsboat wouldn't quit\n", stderr)
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
            waitForExit(pid: pid, triesLeft: triesLeft - 1,
                        completion: completion)
        }
    }

    /// How the mirror comes up: a fresh newsboat sits on its feed list at
    /// the top, a running one is wherever the screen said it was.
    private enum ArmHow {
        case launch
        case resume(NewsboatScreen.Layer?)
    }

    private func arm(feeds: [NewsboatURLEntry], retriesLeft: Int, how: ArmHow) {
        guard entering else { return }
        // Marduk was toggled off while newsboat spun up — never arm a
        // capture the user can't see
        guard isEngaged() else { entering = false; return }
        // No live newsboat = the launch failed (Terminal missing, the
        // Automation grant denied, newsboat crashed). Arming anyway would
        // post arrow keys into whatever app IS frontmost.
        guard NewsboatLocator.runningPID(cachePath: env?.cacheFile ?? "") != nil else {
            if retriesLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                    arm(feeds: feeds, retriesLeft: retriesLeft - 1, how: how)
                }
                return
            }
            entering = false
            Earcon.error()
            fputs("[news] newsboat never came up — not arming\n", stderr)
            announce("Newsboat didn't start. Check that Marduk may control "
                + "Terminal, in Privacy and Security, Automation.")
            return
        }
        entering = false
        db = NewsboatDB(path: env?.cacheFile ?? "")
        gotoFirstUnread = NewsboatLocator.gotoFirstUnread(
            configText: env?.configFile.flatMap {
                try? String(contentsOfFile: $0, encoding: .utf8)
            })
        let titles = db?.feedTitles() ?? [:]
        refreshCounts(force: true)
        let feedRows = feeds.map { entry in
            NewsSession.Feed(
                title: entry.titleOverride
                    ?? entry.queryName
                    ?? titles[entry.url]
                    ?? entry.url,
                url: entry.url,
                isQuery: entry.isQuery)
        }
        active = true
        setCaptured(true)
        var line: String
        switch how {
        case .launch:
            // A fresh newsboat is on its feed list, row 0 — the one state
            // that needs no screen read. Identify its window by the
            // process running in it and bring it forward: `do script`'s
            // id is a fallback, the located one is the fact, and this is
            // also what makes opening the news put newsboat in front of
            // you (user ruling 2026-08-13).
            session = NewsSession()
            session.feeds = feedRows
            raiseNewsboatWindow()
            fputs("[news] armed — \(feedRows.count) feeds\n", stderr)
            line = currentLine()
        case .resume(let layer):
            line = resume(layer, feedRows: feedRows, reload: true)
            fputs("[news] armed — \(feedRows.count) feeds, resumed on the "
                + "\(session.level == .feeds ? "feed list" : "article list")\n",
                stderr)
        }
        showKeyBar(Self.listKeyBar)
        // Straight into the first title — no feed-count preamble (user
        // ruling 2026-08-04: the count is ceremony, the title is the news)
        if OnceMarker.firstTime("news-hinted") {
            line += " " + Self.helpLine
        }
        announce(line)
        // Triage is `t`, ON DEMAND ONLY (user ruling 2026-08-13, reversing
        // the first-open-of-the-day auto-run): opening the news should
        // hand over the first headline and then get out of the way, not
        // spend the model's thinking time and a spoken summary the user
        // didn't ask for.
    }

    private func fileText(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    private func visibleFeeds(text: String) -> [NewsboatURLEntry] {
        NewsboatURLsParser.parse(text).filter { !$0.hidden }
    }

    // MARK: - Key handling

    func handle(_ command: NewsCommand) {
        if case .exit = command {
            deactivate(quiet: true)  // the tap already stood down + sounded
            return
        }
        guard active else { return }
        switch command {
        case .move(let delta): moveBy(delta)
        case .top: jump(top: true)
        case .bottom: jump(top: false)
        case .open: openCurrent()
        case .back: goBack()
        case .read: readCurrent()
        case .openInBrowser: openInBrowser()
        case .copyLink: copyLink()
        case .rawControl: showKeyBar(Self.rawKeyBar)
        case .markAllRead: markAllRead()
        case .deleteArticle: deleteArticle()
        case .reclaim: reclaim()
        case .search(let query, let direction): search(query, direction)
        case .searchRepeat:
            guard let last = lastSearch else { Earcon.error(); return }
            search(last.query, last.direction)
        case .triage: triage()
        case .exit: break
        }
    }

    /// "/" and "?" — jump to the next matching title. The mirror can't
    /// narrow newsboat's on-screen list, so a search MOVES (posting the
    /// exact arrows) rather than filters; "." re-hunts from the new row.
    private var lastSearch: (query: String, direction: ReadDirection)?

    private func search(_ query: String, _ direction: ReadDirection) {
        lastSearch = (query, direction)
        let titles = session.level == .feeds
            ? session.feeds.map(\.title)
            : session.articles.map(\.title)
        let from = session.level == .feeds ? session.feedIndex
                                          : session.articleIndex
        guard let target = NewsSession.searchTarget(
            titles: titles, from: from, query: query, direction: direction)
        else {
            Earcon.error()  // no match, no wrap — the read-search rule
            return
        }
        moveBy(target - from)
    }

    /// Where an article points: its own link, else the destination in its
    /// show notes — the same ladder `o` walks, so yanking and opening can
    /// never disagree about what the article IS.
    private func articleLink(_ article: NewsSession.Article) -> String? {
        if !article.url.isEmpty { return article.url }
        return db?.content(id: article.id)
            .flatMap(NewsHTML.destination(inBody:))
    }

    /// y — the current article's URL to the clipboard (the feed's URL on
    /// the feed list). URLs are user content: never logged, only copied.
    private func copyLink() {
        let url: String?
        switch session.level {
        case .articles:
            url = session.currentArticle.flatMap { articleLink($0) }
        case .feeds:
            url = session.currentFeed.flatMap { $0.isQuery ? nil : $0.url }
        }
        guard let url, !url.isEmpty else { Earcon.error(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        announce("Link copied.")
    }

    /// C — newsboat's own mark-all-feeds-read, mirrored. Feed list only:
    /// the binding lives there, and posting it anywhere else would act
    /// blind.
    private func markAllRead() {
        guard session.level == .feeds else { Earcon.error(); return }
        ensureTerminalFront({ [self] in
            postKeys(8, true, 1)  // Shift+C
            // Every currently-unread item goes into the ledger — C writes
            // newsboat's MEMORY, and cache.db keeps saying unread until it
            // quits, so without this the very next forced count refresh
            // (goBack, reclaim) resurrected every count in the voice while
            // the TUI showed zero, and goto-first-unread aimed feed entry
            // at rows newsboat had already marked. Delivery-gated like
            // every other ledger write.
            for item in db?.unreadItems() ?? [] {
                ledger.markRead(NewsSession.Article(
                    id: item.id, title: "", url: "", unread: true),
                    feed: item.feed)
            }
            unread = [:]
            lastCountRefresh = Date()
            announce("All feeds read.")
        }, orFail: { [self] in
            Earcon.error()
            announce("Couldn't reach newsboat.")
        })
    }

    /// dd — delete the current article and purge it out of the view, so
    /// it is gone from the screen and from the voice and does not come
    /// back. TWO keys, both semantics read from newsboat's source
    /// (2026-08-27) after two shipped guesses drifted in the field:
    /// Shift+D marks the article READ itself (OP_DELETE calls
    /// mark_article_read) — the old Shift+N was pure risk, a TOGGLE that
    /// flipped the flag the wrong way whenever the mirror's unread guess
    /// was stale — and advances the cursor one row except on the last;
    /// `$` purges the row out of the view, restoring the cursor BY GUID,
    /// which on a last-row delete finds nothing and falls to THE TOP.
    /// The mirror lands wherever newsboat lands, and says so.
    private func deleteArticle() {
        guard let target = session.currentArticle,
              let landing = session.deleteCurrentArticle() else {
            Earcon.error()
            return
        }
        let feed = session.currentFeed?.url ?? ""
        // The ledger records what HAPPENED, not what was intended: its
        // writes ride inside the delivered closure, because a dropped key
        // with a ledger entry already filed would hide an article newsboat
        // still shows — a phantom the mirror could never shake until
        // newsboat quit, the exact desync class the ledger exists to kill.
        ensureTerminalFront { [self] in
            postKeys(2, true, 1)   // Shift+D — delete (marks read itself)
            postKeys(21, true, 1)  // $ — purge-deleted
            // cache.db keeps `deleted = 0` and `unread = 1` until newsboat
            // quits, so the ledger carries both facts until then.
            ledger.markRead(target, feed: feed)
            ledger.markDeleted(target, feed: feed)
        }
        fputs("[news] article deleted\n", stderr)
        if session.articles.isEmpty {
            goBack()
        } else if landing == .top {
            // newsboat is at row 0 now — say where we landed, because a
            // silent jump to a different part of the list reads as the
            // gesture misfiring.
            announce("Top of the list. " + currentLine())
        } else {
            speakCurrent()
        }
    }

    /// Held Escape out of raw-control INSERT: the user drove newsboat
    /// directly (reloads, its own hops, a pager they opened themselves),
    /// so the mirror re-locks the same way re-entry does — read the
    /// layer off the screen, climb out of anything that isn't a list,
    /// and put the cursor back on the mirror's row by absolute position.
    /// The row spoken is where the MIRROR stood; the TUI is brought to it.
    private func reclaim() {
        guard active else { return }
        showKeyBar(Self.listKeyBar)
        locateNewsboat(climbsLeft: 3) { [self] layer in
            guard active else { return }
            refreshCounts(force: true)
            let line = resume(layer, feedRows: session.feeds, reload: false)
            fputs("[news] reclaimed from raw control on the "
                + "\(session.level == .feeds ? "feed list" : "article list")\n",
                stderr)
            announce(line)
        }
    }

    /// Put the mirror and the TUI on the same row, given what the screen
    /// showed. Returns the line to speak. The retained `session` is the
    /// row the user was on; `feedRows` is the (possibly re-pulled) feed
    /// list; `reload` sends newsboat's reload-all once we are on the feed
    /// list (it is a feed-list-only binding — a re-entry that lands in an
    /// article list stays there and reloads nothing).
    ///
    /// Both lists are re-locked by ABSOLUTE position: Home, then the
    /// row's worth of Downs. That is what makes a cursor the user moved
    /// by hand come back into step, and it costs nothing when nothing
    /// moved. An article list whose feed the mirror can't place (a query
    /// feed, a title cut too short to match) is left with q — safe from
    /// there — and the feed list resumed instead, spoken.
    private func resume(_ layer: NewsboatScreen.Layer?,
                        feedRows: [NewsSession.Feed], reload: Bool) -> String {
        let retained = session
        var next = NewsSession()
        next.feeds = feedRows
        var prefix = ""

        if case .articles(let title)? = layer {
            let placed = resumeFeed(title: title, retained: retained,
                                    feeds: feedRows)
            let articles = placed.map { feed in
                ledger.applied(to: db?.articles(feedURL: feed.url) ?? [])
            } ?? []
            if let feedIndex = placed.flatMap({ feed in
                feedRows.firstIndex(where: { $0.url == feed.url })
            }), !articles.isEmpty {
                let feed = feedRows[feedIndex]
                let sameFeed = retained.level == .articles
                    && retained.currentFeed?.url == feed.url
                let row = NewsSession.resumeIndex(
                    retainedID: sameFeed ? retained.currentArticle?.id : nil,
                    in: articles)
                let landing = min(row, NewsSession.resumeRowCap)
                next.feedIndex = feedIndex
                next.enterArticles(articles, startAt: landing)
                postHome(thenDown: landing)
                session = next
                fputs("[news] resumed on the article list, row \(landing)\n",
                      stderr)
                if landing < row { prefix = "Top of the list. " }
                return prefix + feed.title + ". " + currentLine()
            }
            // Newsboat is in an article list the mirror cannot place —
            // q from there is the one climb that is always safe.
            fputs("[news] article list not placeable — backing out to "
                + "the feed list\n", stderr)
            ensureTerminalFront { [self] in postKeys(12, false, 1) }  // q
            prefix = "Back on the feed list. "
        } else if layer == nil {
            // The screen could not be read or recognised. The old blind
            // assumption, but SPOKEN — a silent wrong guess is the bug
            // this path replaces. Home is harmless in every dialog.
            prefix = "Couldn't see newsboat's screen. Assuming the feed list. "
        }

        // The feed list: the row the user was on, if that feed survived
        // the feed-list pull, else the top.
        let row = retained.currentFeed.flatMap { feed in
            feedRows.firstIndex(where: { $0.url == feed.url })
        } ?? 0
        let landing = min(row, NewsSession.resumeRowCap)
        next.feedIndex = landing
        postHome(thenDown: landing)
        if reload {
            // Feeds refresh on every open (user ruling). A key we can't
            // deliver is a reload that didn't happen — say so rather than
            // pretending the feeds are fresh.
            ensureTerminalFront({ [self] in
                postKeys(15, true, 1)  // Shift+R — reload-all
                fputs("[news] reload-all keystroke sent\n", stderr)
            }, orFail: { [self] in
                Earcon.error()
                announce("Couldn't reload the feeds. Terminal "
                    + "wouldn't come forward.")
            })
        }
        session = next
        fputs("[news] resumed on the feed list, row \(landing)\n", stderr)
        if landing < row { prefix += "Top of the list. " }
        return prefix + currentLine()
    }

    /// Which feed an article-list title line belongs to. The feed the
    /// mirror was already in wins when the title agrees with it (or the
    /// format printed none); otherwise the title is looked up in the
    /// list. Feed titles are user content — never logged.
    private func resumeFeed(title: String?, retained: NewsSession,
                            feeds: [NewsSession.Feed]) -> NewsSession.Feed? {
        let inFeed = retained.level == .articles ? retained.currentFeed : nil
        guard let title, !title.isEmpty else { return inFeed }
        if let inFeed, inFeed.title == title || inFeed.title.hasPrefix(title) {
            return inFeed
        }
        return NewsSession.feedRow(titled: title, in: feeds).map { feeds[$0] }
    }

    /// Home, then `steps` Downs — newsboat's own start-of-list key (bound
    /// in every dialog) followed by the row. Both ride the delivery FIFO
    /// behind whatever climb preceded them.
    private func postHome(thenDown steps: Int) {
        ensureTerminalFront({ [self] in
            postKeys(115, false, 1)                       // Home
            if steps > 0 { postKeys(125, false, steps) }  // Down × steps
        }, orFail: { [self] in
            Earcon.error()
            announce("Couldn't reach newsboat.")
        })
    }

    /// Read which dialog newsboat is showing and climb out of any that
    /// isn't a list — q closes the pager, help, the URL view, search
    /// results, the dialog list — re-reading after each step. q is NEVER
    /// posted on the feed list (it quits newsboat) or on a screen we
    /// couldn't read (it could be anything); those come back as they are.
    private func locateNewsboat(climbsLeft: Int,
                                completion: @escaping (NewsboatScreen.Layer?) -> Void) {
        readScreen { [self] layer in
            guard active || entering else { return }
            fputs("[news] screen: \(NewsboatScreen.logName(layer))\n", stderr)
            guard NewsboatScreen.climbsOut(of: layer) else {
                completion(layer)
                return
            }
            guard climbsLeft > 0 else {
                fputs("[news] still not on a list after climbing — "
                    + "giving up\n", stderr)
                completion(nil)
                return
            }
            ensureTerminalFront({ [self] in
                postKeys(12, false, 1)  // q — back to the previous dialog
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                    locateNewsboat(climbsLeft: climbsLeft - 1,
                                   completion: completion)
                }
            }, orFail: { completion(nil) })
        }
    }

    /// Terminal's screen text, matched against the compiled title
    /// signatures. The AX read is OFF-MAIN (synchronous IPC, the tap
    /// rule); the verdict hops back. Logs sizes and the dialog name only.
    private func readScreen(_ completion: @escaping (NewsboatScreen.Layer?) -> Void) {
        guard let pid = NSRunningApplication
                .runningApplications(withBundleIdentifier: Self.terminalBundle)
                .first?.processIdentifier else {
            completion(nil)
            return
        }
        let signatures = screenSignatures
        DispatchQueue.global(qos: .userInitiated).async {
            let text = Self.terminalScreenText(pid: pid)
            if let text {
                fputs("[news] read \(text.count) chars of Terminal's screen\n",
                      stderr)
            } else {
                fputs("[news] couldn't read Terminal's screen over AX\n", stderr)
            }
            let layer = text.flatMap {
                NewsboatScreen.detect(screen: $0, signatures: signatures)
            }
            DispatchQueue.main.async { completion(layer) }
        }
    }

    /// The text on screen in Terminal's focused window. OFF-MAIN ONLY.
    /// The focused element when it is the terminal view, else a short
    /// descent from the focused window to its text area. The VISIBLE
    /// character range is preferred — newsboat runs on the alternate
    /// screen, but a Terminal value can be a 9M-char scrollback (the R
    /// field incident), and the title line is on screen by definition —
    /// with the value's last lines as the fallback.
    static func terminalScreenText(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var area: AXUIElement?
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
               app, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let raw = focusedRef, CFGetTypeID(raw) == AXUIElementGetTypeID() {
            let element = raw as! AXUIElement
            if role(of: element) == "AXTextArea" { area = element }
        }
        if area == nil {
            var windowRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                      app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
                  let raw = windowRef, CFGetTypeID(raw) == AXUIElementGetTypeID()
            else { return nil }
            var budget = 200
            area = textArea(below: raw as! AXUIElement, depth: 8, budget: &budget)
        }
        guard let area else { return nil }
        AXUIElementSetMessagingTimeout(area, 0.5)
        var visRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
               area, kAXVisibleCharacterRangeAttribute as CFString, &visRef) == .success,
           let vr = visRef, CFGetTypeID(vr) == AXValueGetTypeID() {
            var range = CFRange(location: 0, length: 0)
            if AXValueGetValue(vr as! AXValue, .cfRange, &range), range.length > 0,
               let param = AXValueCreate(.cfRange, &range) {
                var strRef: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                       area, kAXStringForRangeParameterizedAttribute as CFString,
                       param, &strRef) == .success,
                   let text = strRef as? String, !text.isEmpty {
                    return text
                }
            }
        }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  area, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String, !value.isEmpty else { return nil }
        // The screen is the newest output — keep the tail only
        return value.components(separatedBy: "\n").suffix(200)
            .joined(separator: "\n")
    }

    private static func role(of element: AXUIElement) -> String? {
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, kAXRoleAttribute as CFString, &roleRef) == .success
        else { return nil }
        return roleRef as? String
    }

    /// First AXTextArea at or below `element`, budgeted (nodes, depth,
    /// short per-element timeouts) like every AX walk in this project.
    private static func textArea(below element: AXUIElement, depth: Int,
                                 budget: inout Int) -> AXUIElement? {
        guard depth > 0, budget > 0 else { return nil }
        budget -= 1
        AXUIElementSetMessagingTimeout(element, 0.25)
        if role(of: element) == "AXTextArea" { return element }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let hit = textArea(below: child, depth: depth - 1, budget: &budget) {
                return hit
            }
        }
        return nil
    }

    private func moveBy(_ delta: Int) {
        let steps = session.move(delta)
        guard steps != 0 else { Earcon.error(); return }
        postArrows(steps)
        speakCurrent()
    }

    private func jump(top: Bool) {
        let steps = top ? session.jumpTop() : session.jumpBottom()
        guard steps != 0 else { Earcon.error(); return }
        // A truncated article mirror must never claim newsboat's real
        // bottom row — refuse honestly instead of landing rows apart
        if !top, session.level == .articles,
           session.articles.count >= NewsboatDB.articleLimit {
            _ = session.move(-steps)
            Earcon.error()
            return
        }
        postArrows(steps)
        speakCurrent()
    }

    private func openCurrent() {
        switch session.level {
        case .feeds:
            guard let feed = session.currentFeed else { Earcon.error(); return }
            guard !feed.isQuery else {
                Earcon.error()
                announce("Query feeds aren't mirrored yet.")
                return
            }
            let articles = ledger.applied(to: db?.articles(feedURL: feed.url) ?? [])
            guard !articles.isEmpty else {
                Earcon.error()
                announce("No articles here yet. Feeds may still be refreshing.")
                return
            }
            ensureTerminalFront { [self] in postKeys(36, false, 1) }  // Return
            // Start where newsboat's cursor starts: first unread under
            // the default goto-first-unread, else the top row
            let start = gotoFirstUnread
                ? NewsSession.firstUnreadIndex(articles) : 0
            session.enterArticles(articles, startAt: start)
            announce("\(feed.title). \(articles.count) articles. " + currentLine())
        case .articles:
            readCurrent()
        }
    }

    private func goBack() {
        switch session.level {
        case .articles:
            ensureTerminalFront { [self] in postKeys(12, false, 1) }  // q
            session.backToFeeds()
            refreshCounts(force: true)
            speakCurrent()
        case .feeds:
            // q from the feed list quits newsboat itself — mirror that,
            // hand the keyboard back, and say so. ORDER IS EVERYTHING
            // here, and the first shipping of this got it wrong twice
            // over (field 2026-08-27, the "sheet in Terminal" log line):
            // deactivate() ran synchronously while the q was still in
            // the delivery queue, so the queued continuation failed its
            // own `guard active` and the q was NEVER POSTED — and the
            // 0.8s close timer then told Terminal to close a window
            // whose newsboat was still running, raising the "terminate
            // running processes?" sheet, killing newsboat without its
            // cache.db flush, after ledger.forget() had already
            // discarded the only other record of the session's reads
            // and deletes.
            //
            // So: capture state, DELIVER the q, and only then tear down
            // — with everything downstream of the quit waiting on the
            // PID actually dying, not on a hopeful delay, because the
            // flush is what makes forgetting the ledger legal.
            let window = terminalWindowID != nil
                && terminalWindowID == launchedWindowID
                ? terminalWindowID : nil
            let pid = NewsboatLocator.runningPID(
                cachePath: env?.cacheFile ?? "")
            ensureTerminalFront({ [self] in
                postKeys(12, false, 1)  // q — newsboat quits and flushes
                finishQuit(window: window, pid: pid)
            }, orFail: { [self] in
                // The q never reached newsboat: it is still running, its
                // state unflushed — keep the ledger, leave the window.
                deactivate(quiet: true)
                announce("News closed.")
            })
        }
    }

    /// The back half of quitting: tear the mirror down, then wait for
    /// newsboat's PID to actually exit before forgetting the ledger
    /// (the quit flush is what writes our recorded reads and deletes
    /// into cache.db) and before closing the window Marduk launched
    /// (closing it any earlier raises Terminal's terminate-processes
    /// sheet). A newsboat that will not die keeps both: an honest
    /// leftover window beats a killed flush.
    private func finishQuit(window: Int?, pid: Int32?) {
        deactivate(quiet: true)
        announce("News closed.")
        guard let pid else {
            // Nothing was running — nothing to wait on, nothing unflushed.
            ledger.forget()
            closeOwnedWindow(window)
            return
        }
        // Generous: a quit landing mid-reload is answered only after
        // newsboat JOINS its reload threads (source-verified), and a
        // 41-feed refresh holds the process alive well past a polite
        // wait — the field log's "newsboat wouldn't quit" was this, not
        // a lost keystroke.
        waitForExit(pid: pid, triesLeft: 60) { [self] exited in
            guard exited else {
                fputs("[news] newsboat still running after q — "
                    + "ledger and window kept\n", stderr)
                return
            }
            ledger.forget()
            closeOwnedWindow(window)
        }
    }

    private func closeOwnedWindow(_ window: Int?) {
        guard let window else { return }
        windowQueue.async {
            _ = Self.runWindowScript(Self.closeScript(id: window))
            fputs("[news] closed newsboat's Terminal window\n", stderr)
        }
    }

    private func readCurrent() {
        guard session.level == .articles, let article = session.currentArticle else {
            Earcon.error()
            return
        }
        let body = db?.content(id: article.id).map(NewsHTML.text(from:)) ?? ""
        guard !body.isEmpty else {
            Earcon.error()
            announce("This article has no text. Press o to open it in the browser.")
            return
        }
        // Enter opens newsboat's pager — newsboat marks the article read
        // The pager Enter marks it read in NEWSBOAT — so the ledger entry
        // rides the delivered key, never the intent (a dropped Enter with
        // the entry already filed would desync the mirror durably). The
        // article value is captured before the mirror clears its flag, so
        // the ledger still learns whether it was one of the unread.
        let feed = session.currentFeed?.url ?? ""
        ensureTerminalFront { [self] in
            postKeys(36, false, 1)
            ledger.markRead(article, feed: feed)
        }
        session.markCurrentArticleRead()
        readInFlight = true
        showKeyBar(Self.readingKeyBar)
        fputs("[news] reading article (\(body.count) chars)\n", stderr)
        startRead("\(article.title).\n\n\(body)")
    }

    /// o — open the article. A LADDER, because not every feed gives its
    /// items a link: the item's OWN link first (newsboat opens it), else
    /// the destination in the show notes (Marduk opens it). Either way the
    /// browser activating stands NEWS mode down (the workspace watcher);
    /// n re-opens with a fresh mirror.
    private func openInBrowser() {
        guard session.level == .articles,
              let article = session.currentArticle else {
            Earcon.error()
            return
        }
        // Rung 1: a link the FEED gave us is newsboat's business — posting
        // its own o opens it and marks the article read in one gesture.
        // Never second-guessed with the body: a news article that merely
        // EMBEDS a video must still open the article.
        if !article.url.isEmpty {
            fputs("[news] opening the item's link\n", stderr)
            let feed = session.currentFeed?.url ?? ""
            ensureTerminalFront { [self] in
                postKeys(31, false, 1)  // o — opens AND marks read
                ledger.markRead(article, feed: feed)
            }
            session.markCurrentArticleRead()
            announce("Opening in the browser.")
            return
        }
        // Rung 2: no <link> at all — podcast feeds routinely ship none, so
        // newsboat's o has nothing to open and the destination lives in the
        // show notes. URLs are user content: the RUNG is logged, never the
        // link.
        guard let body = db?.content(id: article.id),
              let link = NewsHTML.destination(inBody: body),
              let url = URL(string: link) else {
            Earcon.error()
            announce("This article has no link.")
            return
        }
        fputs("[news] opening a link from the show notes"
            + (NewsHTML.isVideo(link) ? " (video)\n" : "\n"), stderr)
        NSWorkspace.shared.open(url)
        session.markCurrentArticleRead()
        announce("Opening in the browser.")
    }

    /// Every read completion funnels here from the daemon. Only a read WE
    /// started closes newsboat's pager; a replacement read (readActive
    /// again already) keeps the pager for its own end.
    func readEnded(readActive: Bool) {
        guard readInFlight, !readActive else { return }
        readInFlight = false
        guard active else { return }
        ensureTerminalFront { [self] in postKeys(12, false, 1) }  // q — close pager
        showKeyBar(Self.listKeyBar)
        fputs("[news] article read ended — back to the list\n", stderr)
    }

    /// Ctrl+Option+M, app-switch stand-down, teardown.
    func deactivate(quiet: Bool) {
        guard active || entering else { return }
        active = false
        entering = false
        readInFlight = false
        setCaptured(false)
        hideKeyBar()
        db = nil
        // Never carry a window across opens: the next `n` may launch a new
        // one, and a stale id would either refuse every key or — worse —
        // aim at a window Terminal has since given to something else.
        terminalWindowID = nil
        launchedWindowID = nil
        windowVerified = false
        windowCheckedAt = .distantPast
        fputs("[news] closed\n", stderr)
        if !quiet { announce("News closed.") }
    }

    // MARK: - Speech

    private func speakCurrent() {
        announce(currentLine())
    }

    private func currentLine() -> String {
        switch session.level {
        case .feeds:
            guard let feed = session.currentFeed else { return "No feeds." }
            refreshCounts(force: false)
            return NewsSession.feedLine(title: feed.title,
                                        unread: unread[feed.url] ?? 0,
                                        isQuery: feed.isQuery)
        case .articles:
            guard let article = session.currentArticle else { return "No articles." }
            return NewsSession.articleLine(title: article.title,
                                           unread: article.unread)
        }
    }

    /// Unread counts drift while `-r` refreshes in the background — requery
    /// at most every few seconds so feed lines stay honest without a
    /// query per keypress.
    private func refreshCounts(force: Bool) {
        guard force || Date().timeIntervalSince(lastCountRefresh) > 3 else { return }
        lastCountRefresh = Date()
        if db == nil { db = NewsboatDB(path: env?.cacheFile ?? "") }
        unread = ledger.applied(to: db?.unreadCounts() ?? [:])
    }

    // MARK: - Triage (local Ollama: top-3 + dedup over unread headlines)

    private var triageGeneration = 0

    private var ollamaBase: String {
        newsConfig?.ollamaURL ?? "http://127.0.0.1:11434"
    }

    /// The whole flow: collect unread → model → spoken top-3 → 1/2/3
    /// jump window. Headlines go to LOCALHOST only and are never logged.
    private func triage() {
        guard active else { return }
        if db == nil { db = NewsboatDB(path: env?.cacheFile ?? "") }
        let feedNames = feedTitleByURL()
        let rows = db?.unreadItems(limit: 60) ?? []
        let items = rows.map { row in
            NewsTriage.Item(id: row.id,
                            feedTitle: feedNames[row.feedURL] ?? "a feed",
                            title: row.title)
        }
        guard !items.isEmpty else {
            announce("Nothing unread to triage.")
            return
        }
        // Every triage is asked for now, so every one acknowledges.
        announce("Triaging \(items.count) headlines.")
        fputs("[news] triage — \(items.count) headlines\n", stderr)
        triageGeneration += 1
        let generation = triageGeneration
        let base = ollamaBase
        let configuredModel = newsConfig?.ollamaModel
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Self.runTriage(base: base,
                                         configuredModel: configuredModel,
                                         items: items)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active,
                      generation == self.triageGeneration else { return }
                self.triageArrived(outcome)
            }
        }
    }

    private enum TriageOutcome {
        case result(NewsTriage.Result)
        case failure(String)   // spoken, honest
    }

    private static func runTriage(base: String, configuredModel: String?,
                                  items: [NewsTriage.Item]) -> TriageOutcome {
        // Server lifecycle (user ruling 2026-08-05): a silent Ollama is
        // STARTED for the triage and shut down again when it finishes,
        // so the model isn't parked in RAM between reads. The paired
        // release only stops a server acquire spawned — one the user
        // runs themselves is never touched (ownership doctrine).
        let server = OllamaServer.shared.acquire(base: base)
        defer { OllamaServer.shared.release() }
        switch server {
        case .alreadyRunning, .started:
            break
        case .notLocal:
            return .failure("Ollama isn't answering at the configured URL.")
        case .notInstalled:
            return .failure("Ollama isn't installed. "
                + "Say brew install ollama.")
        case .failed:
            return .failure("Ollama wouldn't start. Press t to retry.")
        }
        guard let tags = curl(url: "\(base)/api/tags", body: nil, timeout: 10),
              let tagsRoot = try? JSONSerialization.jsonObject(with: tags)
                as? [String: Any] else {
            return .failure("Ollama isn't answering. Is it running?")
        }
        let available = (tagsRoot["models"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }
        guard let model = NewsTriage.pickModel(configured: configuredModel,
                                               available: available) else {
            return .failure("Ollama has no models installed.")
        }
        fputs("[news] triage model: \(model)\n", stderr)
        let payload: [String: Any] = [
            "model": model,
            "prompt": NewsTriage.prompt(items: items),
            "stream": false,
            "format": "json",
            "options": ["temperature": 0],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let data = curl(url: "\(base)/api/generate", body: body,
                              timeout: 90),
              let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            return .failure("The model didn't answer in time. "
                + "Press t to retry.")
        }
        if let error = root["error"] as? String, !error.isEmpty {
            fputs("[news] triage — ollama error (\(error.count) chars)\n", stderr)
            return .failure("Ollama refused: check the model name in "
                + "the news config.")
        }
        guard let response = root["response"] as? String,
              let result = NewsTriage.parse(response: response, items: items)
        else {
            return .failure("The model's answer didn't parse. "
                + "Press t to retry.")
        }
        return .result(result)
    }

    /// curl with the body over STDIN — headline text never touches a
    /// shell argument. Returns nil on any failure.
    private static func curl(url: String, body: Data?,
                             timeout: Int) -> Data? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        var arguments = ["-s", "-m", String(timeout), url]
        if body != nil {
            arguments += ["-X", "POST", "-H", "Content-Type: application/json",
                          "--data-binary", "@-"]
        }
        task.arguments = arguments
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        if body != nil { task.standardInput = stdin }
        do { try task.run() } catch { return nil }
        if let body {
            stdin.fileHandleForWriting.write(body)
            stdin.fileHandleForWriting.closeFile()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    private func triageArrived(_ outcome: TriageOutcome) {
        // Never talk over a read the user chose meanwhile — the drop is
        // logged and t re-runs (slower now that an owned server is shut
        // down after each triage — the model reloads on retry)
        guard !isReadPlaying() else {
            fputs("[news] triage result dropped — a read is playing\n", stderr)
            return
        }
        switch outcome {
        case .failure(let spokenError):
            fputs("[news] triage failed\n", stderr)
            Earcon.error()
            announce(spokenError)
        case .result(let result):
            fputs("[news] triage: top \(result.top.count), "
                + "\(result.duplicatesCollapsed) dupes\n", stderr)
            let keys = Set((1...result.top.count).map {
                Character("\($0)")
            })
            announceThen(NewsTriage.spoken(result)) { [weak self] in
                guard let self, self.active else { return }
                self.armChoice(keys) { [weak self] answer in
                    guard let self, let n = answer.wholeNumberValue,
                          n >= 1, n <= result.top.count else { return }
                    self.jumpToTriaged(result.top[n - 1].item)
                }
            }
        }
    }

    /// Glide the mirror AND the TUI to a triaged story, then read it:
    /// unwind to the feed list, walk to its feed, open, walk to the row,
    /// R. Each step is a real primitive with the usual posting rules;
    /// generation-guarded so an exit mid-glide stops the sequence.
    private func jumpToTriaged(_ item: NewsTriage.Item) {
        guard active else { return }
        triageGeneration += 1
        let generation = triageGeneration
        let step: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.active,
                      generation == self.triageGeneration else { return }
                work()
            }
        }
        // 1. Unwind to the feed list
        if session.level == .articles {
            ensureTerminalFront { [self] in postKeys(12, false, 1) }  // q
            session.backToFeeds()
        }
        // 2. Find the feed by matching the article id into each feed's
        //    list is wasteful — the db row carries the feed URL instead
        guard let feedURL = db?.articleFeedURL(id: item.id),
              let feedTarget = session.feeds.firstIndex(where: {
                  $0.url == feedURL
              }) else {
            Earcon.error()
            announce("That story is gone.")
            return
        }
        step(0.4) { [self] in
            let delta = feedTarget - session.feedIndex
            if delta != 0 {
                _ = session.move(delta)
                postArrows(delta)
            }
            // 3. Open the feed (speaks its line), then walk to the row
            step(0.45) { [self] in
                openCurrent()
                step(0.45) { [self] in
                    guard session.level == .articles,
                          let rowTarget = session.articles.firstIndex(where: {
                              $0.id == item.id
                          }) else {
                        Earcon.error()
                        announce("That story is gone.")
                        return
                    }
                    let rowDelta = rowTarget - session.articleIndex
                    if rowDelta != 0 {
                        _ = session.move(rowDelta)
                        postArrows(rowDelta)
                    }
                    step(0.35) { [self] in readCurrent() }
                }
            }
        }
    }

    private func feedTitleByURL() -> [String: String] {
        var names: [String: String] = [:]
        for feed in session.feeds { names[feed.url] = feed.title }
        return names
    }

    // MARK: - Terminal plumbing

    private func postArrows(_ steps: Int) {
        // The one cached call site: j/k autorepeat glides would otherwise
        // spawn an osascript per repeat, and a stray arrow in a shell is
        // the cheapest key we post.
        ensureTerminalFront({ [self] in
            postKeys(steps > 0 ? 125 : 126, false, abs(steps))  // Down / Up
        }, cached: true)
    }

    /// Posted keys land wherever focus is — make sure that's Terminal, and
    /// if Terminal never comes forward, post NOTHING (a stray arrow in the
    /// wrong app beats out an invisible wrong action in newsboat, but
    /// nothing beats both). `orFail` is for keys whose loss the user must
    /// HEAR about — a dropped arrow is self-evident, a dropped reload is
    /// silently stale news.
    ///
    /// TERMINAL IS NOT A WINDOW. The bundle check above says the keys will
    /// reach Terminal.app; it says NOTHING about WHICH of its windows, and
    /// a user with newsboat in one window and a shell in another is the
    /// normal case, one Cmd+` apart. Field 2026-08-13: with the shell
    /// window front, every posted key went there — arrows harmlessly, but
    /// `d`'s Shift+D deleted six articles out of the newsboat the user
    /// could not see, and the deleted flag is keyed by guid and permanent.
    /// So the window `do script` handed us is checked too, and a mismatch
    /// stands the mirror down exactly like an app switch (user ruling):
    /// Marduk must never drive a screen the user has navigated away from.
    ///
    /// `cached` is for the arrow path ONLY, where autorepeat glides would
    /// otherwise spawn an osascript per repeat. Every other key — and
    /// every destructive one — pays for a fresh answer.
    private func ensureTerminalFront(_ action: @escaping () -> Void,
                                     cached: Bool = false,
                                     orFail: (() -> Void)? = nil) {
        // The FIFO covers the ACTIVATION branch too. The first ordering
        // fix serialized only the window check, so a key parked 0.35s
        // waiting for Terminal to come forward was still overtaken by a
        // later key that found Terminal already front — the same j-beats-d
        // reorder through the branch the fix didn't route (review finding,
        // 2026-08-27; the frontmost cache is documented to flap). Every
        // call now takes a windowQueue slot IN CALL ORDER and holds it
        // until its whole delivery resolves — activation wait, window
        // check, action — so nothing asked later can land earlier. The
        // wait is bounded well above the worst honest path (0.35s
        // activation + a watchdogged osascript), because a lost signal
        // must strand one key, never the queue.
        windowQueue.async { [self] in
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { [self] in
                deliverToTerminal(action, cached: cached, orFail: orFail) {
                    done.signal()
                }
            }
            if done.wait(timeout: .now() + 8) == .timedOut {
                fputs("[news] delivery timed out — releasing the key "
                    + "queue\n", stderr)
            }
        }
    }

    /// The main-queue half of a delivery: frontmost check (with one
    /// activate-and-retry), then the window check, then the action.
    /// `completion` fires at EVERY exit — it is what releases the FIFO.
    private func deliverToTerminal(_ action: @escaping () -> Void,
                                   cached: Bool,
                                   orFail: (() -> Void)?,
                                   completion: @escaping () -> Void) {
        guard frontmostApp() == Self.terminalBundle else {
            activateTerminal()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in
                guard frontmostApp() == Self.terminalBundle else {
                    fputs("[news] Terminal wouldn't come forward — "
                        + "key dropped\n", stderr)
                    orFail?()
                    completion()
                    return
                }
                ensureNewsWindowFront(action, cached: false, orFail: orFail,
                                      completion: completion)
            }
            return
        }
        ensureNewsWindowFront(action, cached: cached, orFail: orFail,
                              completion: completion)
    }

    /// The window half of the check. A fresh answer costs one osascript,
    /// taken OFF-MAIN (the ducker rule) with the action dispatched back.
    private func ensureNewsWindowFront(_ action: @escaping () -> Void,
                                       cached: Bool,
                                       orFail: (() -> Void)?,
                                       completion: @escaping () -> Void = {}) {
        // ORDER IS PART OF THE CONTRACT, and it used to be luck. The cached
        // arrow path acted INLINE while an uncached key — every destructive
        // one — was still waiting on its osascript, so `d` then a quick `j`
        // reached newsboat as `j` then `d`: the cursor moved first and the
        // delete landed on the NEXT article. Field 2026-08-27, and the
        // three-key delete made it worse than a mis-aimed delete, because
        // the mark-read rode along: "it still marked it as read and removed
        // the N… I wanted to save it for later."
        //
        // So EVERY post now goes through the same serial queue in the order
        // it was asked for. `cached` no longer means "act now", it means
        // "skip the osascript" — which is all it was ever for (autorepeat
        // glides must not spawn one per repeat). The cost is a queue hop.
        //
        // The decision is taken HERE, on main, because the cache fields
        // live on main; only the round trip belongs on the queue.
        let reuse = cached && windowVerified && terminalWindowID != nil
            && Date().timeIntervalSince(windowCheckedAt) < Self.windowRecheckInterval
        scriptQueue.async { [self] in
            let front = reuse ? nil : frontTerminalWindowID()
            DispatchQueue.main.async { [self] in
                defer { completion() }
                guard active || entering else { return }
                // Nothing is adopted here. Newsboat's window is IDENTIFIED
                // by the process running in it (`raiseNewsboatWindow`),
                // never inferred from what happens to be in front: on the
                // attach path the front window is routinely the shell the
                // user was last in, and blessing it is precisely how a
                // `d` reached a newsboat nobody could see.
                guard let ours = terminalWindowID else {
                    fputs("[news] no newsboat window to aim at — "
                        + "key dropped\n", stderr)
                    orFail?()
                    standDownOffWindow()
                    return
                }
                if !reuse {
                    windowCheckedAt = Date()
                    windowVerified = (front == ours)
                }
                guard windowVerified else {
                    fputs("[news] front Terminal window isn't newsboat's — "
                        + "key dropped, standing down\n", stderr)
                    orFail?()
                    standDownOffWindow()
                    return
                }
                action()
            }
        }
    }

    /// A window switch is an app switch as far as the mirror is concerned:
    /// silent, no announcement (the user knows they switched), `n` to
    /// resume. Logged, because "news stopped responding" must be
    /// answerable from the log alone.
    private func standDownOffWindow() {
        guard active || entering else { return }
        fputs("[news] stood down — newsboat's window is no longer front\n",
              stderr)
        deactivate(quiet: true)
    }

    /// Close one Terminal window by id. Pure string-building so the
    /// interpolation is testable; the id is an Int, so nothing user-typed
    /// reaches AppleScript source here.
    static func closeScript(id: Int) -> String {
        "tell application \"Terminal\" to close window id \(id)"
    }

    /// Terminal's own window id for its frontmost window, or nil when it
    /// has none / AppleScript fails. Same kill-on-timeout watchdog every
    /// osascript in this project carries.
    private func frontTerminalWindowID() -> Int? {
        Self.runWindowScript(
            "tell application \"Terminal\" to return id of front window")
    }

    /// Run an AppleScript that answers with a Terminal window id (or an
    /// empty reply for "none"). Blocking — callers use `windowQueue`.
    static func runWindowScript(_ script: String) -> Int? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(3)
        while task.isRunning, Date() < deadline { usleep(20_000) }
        if task.isRunning {
            task.terminate()
            fputs("[news] window query timed out — killed\n", stderr)
            return nil
        }
        guard task.terminationStatus == 0,
              let text = String(data: out.fileHandleForReading
                  .readDataToEndOfFile(), encoding: .utf8)
        else { return nil }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Find the window newsboat is ACTUALLY running in and bring it
    /// forward. Terminal knows which processes each tab is running, so
    /// this is a FACT, not the guess it replaced: "the front Terminal
    /// window at entry" is whatever window the user was last in, which on
    /// the attach path is routinely a shell — field 2026-08-13, where
    /// `activateTerminal()` restored that window, every posted key went to
    /// it, and a `d` deleted articles out of a newsboat nobody could see.
    /// The user's ruling is that opening the news brings newsboat forward,
    /// so the raise happens here too, in the same round trip.
    ///
    /// Only a window running our newsboat can be adopted. Not finding one
    /// leaves whatever `do script` gave us and, failing that, nothing —
    /// which posts no keys at all.
    private func raiseNewsboatWindow(completion: (() -> Void)? = nil) {
        let process = newsboatProcessName()
        windowQueue.async { [self] in
            let found = Self.runWindowScript(Self.raiseScript(process: process))
            DispatchQueue.main.async { [self] in
                defer { completion?() }
                guard active || entering else { return }
                if let found {
                    terminalWindowID = found
                    windowVerified = true
                    windowCheckedAt = Date()
                    fputs("[news] newsboat's window brought forward\n", stderr)
                } else {
                    fputs("[news] no Terminal window is running "
                        + "newsboat\n", stderr)
                    // With no window from `do script` either there is
                    // nothing to aim at, and every key will be refused —
                    // say so rather than leaving a mirror that answers
                    // nothing (the honest-failure rule).
                    if terminalWindowID == nil {
                        Earcon.error()
                        announce("Couldn't find newsboat's window.")
                    }
                }
            }
        }
    }

    /// The process name Terminal will report for our newsboat — the
    /// binary's basename, so a custom `news.command` still matches.
    /// Sanitised because it is interpolated into AppleScript source.
    private func newsboatProcessName() -> String {
        let path = env?.binaryPath ?? "newsboat"
        let name = (path as NSString).lastPathComponent
        let safe = name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return safe.isEmpty ? "newsboat" : safe
    }

    /// Ask Terminal which window runs `process`, raise it, and hand back
    /// its id. Pure so the script is testable without a Mac.
    static func raiseScript(process: String) -> String {
        """
        tell application "Terminal"
            set found to 0
            repeat with w in windows
                repeat with t in tabs of w
                    if (processes of t) contains "\(process)" then
                        set found to id of w
                        exit repeat
                    end if
                end repeat
                if found is not 0 then exit repeat
            end repeat
            if found is 0 then return ""
            activate
            set frontmost of window id found to true
            return found
        end tell
        """
    }

    private func activateTerminal() {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.terminalBundle)
            .first?.activate()
    }

    /// `git pull --ff-only` in the urls file's directory when it is a git
    /// clone, answering the question the load depends on: did the feed
    /// list actually CHANGE? Only runs where a `.git` exists — the user
    /// cloned with git, so git is present (never poke /usr/bin/git on a
    /// machine without the CLT: the shim pops a GUI install dialog).
    ///
    /// The completion fires exactly once, on the main queue. It fires at
    /// the SOFT deadline if git is still going, so news never hangs behind
    /// a flaky network; git runs on to the hard deadline regardless, and
    /// whatever it pulls counts for the next open. Feed URLs are user
    /// content — git's output goes to /dev/null and only exit status is
    /// logged.
    private func syncFeedRepo(urlsPath: String,
                              completion: @escaping (FeedRepoSync) -> Void) {
        let dir = (urlsPath as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: dir + "/.git") else {
            completion(.notARepo)
            return
        }
        let before = FileManager.default.contents(atPath: urlsPath)
        DispatchQueue.global(qos: .userInitiated).async {
            var answered = false
            let answer: (FeedRepoSync) -> Void = { result in
                guard !answered else { return }
                answered = true
                DispatchQueue.main.async { completion(result) }
            }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            task.arguments = ["-C", dir, "pull", "--ff-only", "--quiet"]
            // Same hardening as the Karabiner rules pull: a credential
            // prompt nobody can see is a hang, and this private-repo pull
            // burned its whole deadline on every open when auth lapsed.
            var env = ProcessInfo.processInfo.environment
            env["GIT_TERMINAL_PROMPT"] = "0"
            env["GIT_ASKPASS"] = "/usr/bin/true"
            task.environment = env
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
            } catch {
                fputs("[news] feed repo pull wouldn't start\n", stderr)
                answer(.failed(reason: "git wouldn't start"))
                return
            }
            let started = Date()
            while task.isRunning {
                let elapsed = Date().timeIntervalSince(started)
                if elapsed >= Self.hardPullDeadline { break }
                if elapsed >= Self.softPullDeadline { answer(.slow) }
                usleep(100_000)
            }
            if task.isRunning {
                task.terminate()
                fputs("[news] feed repo pull timed out — killed\n", stderr)
                answer(.failed(reason: "timed out"))
                return
            }
            let status = task.terminationStatus
            let changed = FileManager.default.contents(atPath: urlsPath) != before
            fputs("[news] feed repo pull exited \(status)"
                + (changed ? " — feed list changed" : "") + "\n", stderr)
            guard status == 0 else {
                answer(.failed(reason: "git exit \(status)"))
                return
            }
            answer(.synced(changed: changed))
        }
    }

    /// Open a Terminal window running the newsboat command. osascript gets
    /// the standard kill-on-timeout watchdog (the ducker/inverter rule: a
    /// hung System Events must never wedge a queue).
    private func launchInTerminal(_ command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            tell application "Terminal"
                activate
                do script "\(escaped)"
            end tell
            """
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
            // `do script` replies with the tab it created — "tab 1 of
            // window id 3274". That id is the ONLY handle we get on
            // newsboat's window, and every posted key is checked against
            // it, so it goes to a pipe rather than the log.
            let out = Pipe()
            task.standardOutput = out
            do {
                try task.run()
            } catch {
                fputs("[news] Terminal launch failed to start\n", stderr)
                return
            }
            let deadline = Date().addingTimeInterval(10)
            while task.isRunning, Date() < deadline {
                usleep(100_000)
            }
            if task.isRunning {
                task.terminate()
                fputs("[news] Terminal launch timed out — killed\n", stderr)
                return
            }
            guard task.terminationStatus == 0 else {
                fputs("[news] Terminal launch exited "
                    + "\(task.terminationStatus)\n", stderr)
                return
            }
            let reply = String(data: out.fileHandleForReading
                .readDataToEndOfFile(), encoding: .utf8) ?? ""
            let id = Self.windowID(fromDoScriptReply: reply)
            DispatchQueue.main.async { [self] in
                guard active || entering else { return }
                terminalWindowID = id
                launchedWindowID = id
                windowVerified = id != nil
                windowCheckedAt = Date()
                fputs("[news] " + (id != nil
                    ? "newsboat launched in its own Terminal window"
                    : "launch gave no window id — arm will adopt one")
                    + "\n", stderr)
            }
        }
    }

    /// Pull the window id out of `do script`'s reply ("tab 1 of window id
    /// 3274"). Pure so the parse is testable without a Mac.
    static func windowID(fromDoScriptReply reply: String) -> Int? {
        guard let marker = reply.range(of: "window id ") else { return nil }
        let digits = reply[marker.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }
}
