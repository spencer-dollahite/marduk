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
/// Known limits (the Firefox-n "blind toggle" precedent): the mirror
/// assumes newsboat's DEFAULT sort orders and view state — driving
/// newsboat's TUI by hand mid-session, custom sort settings, or attaching
/// to a newsboat that isn't sitting on its feed list can desync the
/// mirror until the next `n`. All main-thread; the store's SQLite reads
/// are small and read-only.
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
    // Where newsboat parks the article-list cursor on feed entry —
    // parsed from the effective config at arm time
    private var gotoFirstUnread = true

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
        // Every open pulls the feed list and reloads every feed (user
        // ruling) — say so up front, so the gesture is acknowledged even
        // when the network makes the rest of it slow.
        announce("News. Reloading feeds.")
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

    private func startNewsboat(feeds: [NewsboatURLEntry], attached: Bool) {
        guard let env else { entering = false; return }
        fputs("[news] loading (\(attached ? "attach" : "launch"))"
            + " — \(feeds.count) feeds\n", stderr)
        if attached {
            activateTerminal()
            // Feeds refresh on every load (user ruling): a fresh launch
            // carries -r, an attach gets newsboat's reload-all keystroke.
            // A key we can't deliver is a reload that didn't happen — say
            // so rather than pretending the feeds are fresh.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
                guard entering else { return }
                ensureTerminalFront({ [self] in
                    postKeys(15, true, 1)  // Shift+R — reload-all
                }, orFail: { [self] in
                    Earcon.error()
                    announce("Couldn't reload the feeds. Terminal wouldn't "
                        + "come forward.")
                })
            }
        } else {
            launchInTerminal(NewsboatLocator.launchCommand(env,
                                                           command: newsConfig?.command))
        }
        // Arm once the TUI can take keys — before that, a posted arrow
        // would land in the shell prompt.
        let armDelay: TimeInterval = attached ? 1.2 : 2.2
        DispatchQueue.main.asyncAfter(deadline: .now() + armDelay) { [self] in
            arm(feeds: feeds, retriesLeft: 2)
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

    private func arm(feeds: [NewsboatURLEntry], retriesLeft: Int) {
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
                    arm(feeds: feeds, retriesLeft: retriesLeft - 1)
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
        session = NewsSession()
        session.feeds = feeds.map { entry in
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
        showKeyBar(Self.listKeyBar)
        fputs("[news] armed — \(session.feeds.count) feeds\n", stderr)
        // Straight into the first title — no feed-count preamble (user
        // ruling 2026-08-04: the count is ceremony, the title is the news)
        var line = currentLine()
        if OnceMarker.firstTime("news-hinted") {
            line += " " + Self.helpLine
        }
        announce(line)
        // First open of the day triages automatically (user ruling);
        // t re-runs on demand. The stamp is a yyyymmdd counted marker.
        let today = Self.dayStamp()
        if OnceMarker.count("news-triaged") != today {
            OnceMarker.setCount("news-triaged", today)
            triage(auto: true)
        }
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
        case .triage: triage(auto: false)
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

    /// c — the current article's URL to the clipboard (the feed's URL on
    /// the feed list). URLs are user content: never logged, only copied.
    private func copyLink() {
        let url: String?
        switch session.level {
        case .articles:
            url = session.currentArticle?.url
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
        ensureTerminalFront { [self] in postKeys(8, true, 1) }  // Shift+C
        unread = [:]
        lastCountRefresh = Date()  // the db lags newsboat's write — don't
                                   // requery a stale count right away
        announce("All feeds read.")
    }

    /// dd — delete the current article (newsboat's D). The article
    /// vanishes from newsboat's list in place, cursor on the next row —
    /// the mirror does the same and speaks where you landed.
    private func deleteArticle() {
        let deleted = session.currentArticle
        guard session.deleteCurrentArticle() else { Earcon.error(); return }
        ensureTerminalFront { [self] in postKeys(2, true, 1) }  // Shift+D
        fputs("[news] article deleted\n", stderr)
        if session.articles.isEmpty {
            _ = deleted
            goBack()
        } else {
            speakCurrent()
        }
    }

    /// Held Escape out of raw-control INSERT: the user drove newsboat
    /// directly (reloads, its own n/N hops), so refresh the mirror's DATA.
    /// The TUI cursor can't be observed — the row we speak is where the
    /// MIRROR still stands (documented limit; j/k re-lock the two).
    private func reclaim() {
        guard active else { return }
        refreshCounts(force: true)
        if session.level == .articles, let feed = session.currentFeed {
            let fresh = db?.articles(feedURL: feed.url) ?? []
            let keepID = session.currentArticle?.id
            let start = keepID.flatMap { id in fresh.firstIndex { $0.id == id } }
                ?? min(session.articleIndex, max(0, fresh.count - 1))
            session.enterArticles(fresh, startAt: start)
        }
        showKeyBar(Self.listKeyBar)
        fputs("[news] reclaimed from raw control\n", stderr)
        speakCurrent()
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
            let articles = db?.articles(feedURL: feed.url) ?? []
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
            // hand the keyboard back, and say so.
            ensureTerminalFront { [self] in postKeys(12, false, 1) }
            deactivate(quiet: true)
            announce("News closed.")
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
        ensureTerminalFront { [self] in postKeys(36, false, 1) }
        session.markCurrentArticleRead()
        readInFlight = true
        showKeyBar(Self.readingKeyBar)
        fputs("[news] reading article (\(body.count) chars)\n", stderr)
        startRead("\(article.title).\n\n\(body)")
    }

    private func openInBrowser() {
        guard session.level == .articles, session.currentArticle != nil else {
            Earcon.error()
            return
        }
        // newsboat's own o — it opens the configured browser and marks the
        // article read. The browser activating stands NEWS mode down (the
        // workspace watcher); n re-opens with a fresh mirror.
        ensureTerminalFront { [self] in postKeys(31, false, 1) }  // o
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
        unread = db?.unreadCounts() ?? [:]
    }

    // MARK: - Triage (local Ollama: top-3 + dedup over unread headlines)

    private var triageGeneration = 0
    private static func dayStamp() -> Int {
        let parts = Calendar.current.dateComponents([.year, .month, .day],
                                                    from: Date())
        return (parts.year ?? 0) * 10000 + (parts.month ?? 0) * 100
            + (parts.day ?? 0)
    }

    private var ollamaBase: String {
        newsConfig?.ollamaURL ?? "http://127.0.0.1:11434"
    }

    /// The whole flow: collect unread → model → spoken top-3 → 1/2/3
    /// jump window. Headlines go to LOCALHOST only and are never logged.
    private func triage(auto: Bool) {
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
            if !auto { announce("Nothing unread to triage.") }
            return
        }
        // The auto run must not talk over the entry title — announce
        // chains behind it naturally; the manual run acknowledges now.
        if !auto { announce("Triaging \(items.count) headlines.") }
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
                self.triageArrived(outcome, auto: auto)
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

    private func triageArrived(_ outcome: TriageOutcome, auto: Bool) {
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
            if !auto { Earcon.error() }
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
        ensureTerminalFront { [self] in
            postKeys(steps > 0 ? 125 : 126, false, abs(steps))  // Down / Up
        }
    }

    /// Posted keys land wherever focus is — make sure that's Terminal, and
    /// if Terminal never comes forward, post NOTHING (a stray arrow in the
    /// wrong app beats out an invisible wrong action in newsboat, but
    /// nothing beats both). `orFail` is for keys whose loss the user must
    /// HEAR about — a dropped arrow is self-evident, a dropped reload is
    /// silently stale news.
    private func ensureTerminalFront(_ action: @escaping () -> Void,
                                     orFail: (() -> Void)? = nil) {
        if frontmostApp() == Self.terminalBundle {
            action()
            return
        }
        activateTerminal()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in
            guard frontmostApp() == Self.terminalBundle else {
                fputs("[news] Terminal wouldn't come forward — key dropped\n",
                      stderr)
                orFail?()
                return
            }
            action()
        }
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
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
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
            } else if task.terminationStatus != 0 {
                fputs("[news] Terminal launch exited "
                    + "\(task.terminationStatus)\n", stderr)
            }
        }
    }
}
