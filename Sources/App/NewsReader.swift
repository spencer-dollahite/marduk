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

    static let terminalBundle = "com.apple.Terminal"
    static let helpLine = "j and k move. Enter opens. Uppercase R reads the "
        + "article. o opens it in the browser. h goes back. Escape leaves."

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
              !visibleFeeds(urlsPath: urlsPath).isEmpty else {
            Earcon.error()
            announce("Newsboat has no feeds yet. Add feed addresses to your "
                + "newsboat urls file, one per line, then press n again.")
            return
        }

        entering = true
        let attaching = NewsboatLocator.runningPID(cachePath: env.cacheFile) != nil
        fputs("[news] entering (\(attaching ? "attach" : "launch"))\n", stderr)
        announce("News.")
        // The feed list syncs with its repo on every open: when the urls
        // file lives in a git clone (the private-repo pattern), pull
        // quietly before the mirror reads it. Fire-and-forget — offline
        // or conflicted just keeps yesterday's list, and the arm delay
        // usually covers a fast-forward.
        pullNewsRepo(urlsPath: urlsPath)
        if attaching {
            activateTerminal()
            // Feeds refresh on every load (user ruling): a fresh launch
            // carries -r, an attach gets newsboat's reload-all keystroke.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
                guard entering else { return }
                ensureTerminalFront { [self] in postKeys(15, true, 1) }  // Shift+R
            }
        } else {
            launchInTerminal(NewsboatLocator.launchCommand(env,
                                                           command: newsConfig?.command))
        }
        // Arm once the TUI can take keys — before that, a posted arrow
        // would land in the shell prompt.
        let armDelay: TimeInterval = attaching ? 1.2 : 2.2
        DispatchQueue.main.asyncAfter(deadline: .now() + armDelay) { [self] in
            arm(urlsPath: urlsPath, retriesLeft: 2)
        }
    }

    private func arm(urlsPath: String, retriesLeft: Int) {
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
                    arm(urlsPath: urlsPath, retriesLeft: retriesLeft - 1)
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
        session.feeds = visibleFeeds(urlsPath: urlsPath).map { entry in
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
        fputs("[news] armed — \(session.feeds.count) feeds\n", stderr)
        // Straight into the first title — no feed-count preamble (user
        // ruling 2026-08-04: the count is ceremony, the title is the news)
        var line = currentLine()
        if OnceMarker.firstTime("news-hinted") {
            line += " " + Self.helpLine
        }
        announce(line)
    }

    private func visibleFeeds(urlsPath: String) -> [NewsboatURLEntry] {
        guard let text = try? String(contentsOfFile: urlsPath, encoding: .utf8) else {
            return []
        }
        return NewsboatURLsParser.parse(text).filter { !$0.hidden }
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
        case .markAllRead: markAllRead()
        case .deleteArticle: deleteArticle()
        case .reclaim: reclaim()
        case .help: announce(Self.helpLine)
        case .exit: break
        }
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
        fputs("[news] article read ended — back to the list\n", stderr)
    }

    /// Ctrl+Option+M, app-switch stand-down, teardown.
    func deactivate(quiet: Bool) {
        guard active || entering else { return }
        active = false
        entering = false
        readInFlight = false
        setCaptured(false)
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

    // MARK: - Terminal plumbing

    private func postArrows(_ steps: Int) {
        ensureTerminalFront { [self] in
            postKeys(steps > 0 ? 125 : 126, false, abs(steps))  // Down / Up
        }
    }

    /// Posted keys land wherever focus is — make sure that's Terminal, and
    /// if Terminal never comes forward, post NOTHING (a stray arrow in the
    /// wrong app beats out an invisible wrong action in newsboat, but
    /// nothing beats both).
    private func ensureTerminalFront(then action: @escaping () -> Void) {
        if frontmostApp() == Self.terminalBundle {
            action()
            return
        }
        activateTerminal()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in
            guard frontmostApp() == Self.terminalBundle else {
                fputs("[news] Terminal wouldn't come forward — key dropped\n",
                      stderr)
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
    /// clone. Only runs where a `.git` exists — the user cloned with git,
    /// so git is present (never poke /usr/bin/git on a machine without
    /// the CLT: the shim pops a GUI install dialog).
    private func pullNewsRepo(urlsPath: String) {
        let dir = (urlsPath as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: dir + "/.git") else { return }
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            task.arguments = ["-C", dir, "pull", "--ff-only", "--quiet"]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
            } catch {
                fputs("[news] feed repo pull failed to start\n", stderr)
                return
            }
            let deadline = Date().addingTimeInterval(15)
            while task.isRunning, Date() < deadline { usleep(100_000) }
            if task.isRunning {
                task.terminate()
                fputs("[news] feed repo pull timed out — killed\n", stderr)
            } else {
                fputs("[news] feed repo pull exited "
                    + "\(task.terminationStatus)\n", stderr)
            }
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
