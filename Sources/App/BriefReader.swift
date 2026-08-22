import Foundation

/// The DAILY BRIEF (`d`): a spoken morning rundown assembled from the
/// sources Marduk already owns — the clock, a keyless weather service, a
/// note in Notes.app, the `S` watchlist, and the newsboat cache.
///
/// It is a READ, not a string of announcements. That is the one design
/// decision worth arguing about, and it is what makes the brief usable:
/// as a read it gets the whole reading machinery for free — Space pauses
/// it, Escape stops it, `}` skips the weather to get to the headlines
/// (segments are PARAGRAPHS), `/` searches it, `rr` replays it, and media
/// ducks and unducks exactly once around the whole thing. Chained
/// announcements would have given up all of that, and would additionally
/// have had to distinguish "the segment finished" from "the user pressed
/// Escape" — which `announce`'s completion cannot do, since it fires on
/// cancel too.
///
/// Gathering is CONCURRENT and BOUNDED: every segment runs off-main at
/// once and the brief speaks at `gatherDeadline` whatever has arrived, so
/// one hung service can never eat the brief. Nothing is ever spoken while
/// a source is merely slow — a missing segment says so.
///
/// Privacy: `[brief]` logs counts, segment names, and outcomes ONLY.
/// Headlines, note titles, note bodies, and place names are user content
/// and never reach the log.
final class BriefReader {

    // Wired by the daemon
    var announce: (String) -> Void = { _ in }
    /// Announce, then run the completion — the brief waits for the
    /// opening line to finish before starting the read, so a fast gather
    /// can't cut its own introduction off mid-word.
    var announceThen: (String, @escaping () -> Void) -> Void = { _, done in done() }
    /// The full reading path (`Daemon.speakDocument`): chunking, motions,
    /// ducking, follow, replay.
    var startRead: (String) -> Void = { _ in }
    /// Live config — the brief's setup changes under `:config` while the
    /// daemon runs, so it is READ at each press rather than captured once.
    var settings: () -> MardukConfig = { MardukConfig() }
    var isEngaged: () -> Bool = { true }

    static let helpLine = "Say colon segments to choose what it includes. "
        + "Space pauses, right brace skips to the next part, Escape stops."

    /// Speak with whatever has arrived by now. Every fetch already has its
    /// own timeout (curl -m, an osascript watchdog); this is the backstop
    /// for all of them together, so a brief can never simply not happen.
    static let gatherDeadline: TimeInterval = 20

    /// Per-source timeouts, in seconds.
    static let webTimeout = 8
    static let notesTimeout: TimeInterval = 10

    private(set) var running = false
    /// Bumped by every press and by `abort()`. Named apart from the local
    /// `generation` each run captures — a property and a local of the same
    /// name in one scope is a compile error, and the whole guard depends
    /// on comparing the two.
    private var runGeneration = 0
    private var openingDone = false
    private var parts: [BriefSegment: String]?

    // MARK: - Entry

    func run() {
        let config = settings()
        let segments = BriefPlan.resolve(config.brief?.segments)
        guard !segments.isEmpty else {
            Earcon.error()
            announce("Your daily brief has no parts turned on. Say colon "
                + "segments to choose what it includes.")
            return
        }
        // A second d while one is still being assembled restarts it rather
        // than stacking two — the generation bump orphans the first.
        runGeneration += 1
        let generation = runGeneration
        running = true
        openingDone = false
        parts = nil
        fputs("[brief] assembling \(segments.count) segments\n", stderr)

        var opening = "Daily brief."
        if OnceMarker.firstTime("brief-hinted") {
            opening += " " + Self.helpLine
        }
        announceThen(opening) { [weak self] in
            guard let self, generation == self.runGeneration else { return }
            self.openingDone = true
            self.speakIfReady(generation)
        }
        gather(segments, config: config) { [weak self] gathered in
            guard let self, generation == self.runGeneration else { return }
            self.parts = gathered
            self.speakIfReady(generation)
        }
    }

    /// Any stop that isn't ours — Escape, the read button, Ctrl+Option+M —
    /// abandons a brief still being assembled. Once it is SPEAKING the
    /// read owns itself and the normal stop path handles it.
    func abort() {
        guard running else { return }
        running = false
        runGeneration += 1
        fputs("[brief] abandoned before it spoke\n", stderr)
    }

    /// Both halves have to land: the opening line has finished speaking
    /// AND the segments are in. Whichever is last starts the read.
    private func speakIfReady(_ generation: Int) {
        guard running, generation == runGeneration,
              openingDone, let gathered = parts else { return }
        running = false
        // Ctrl+Option+M during the gather means "stand everything down" —
        // a brief must not start talking into a disengaged Marduk.
        guard isEngaged() else {
            fputs("[brief] Marduk was switched off — not speaking\n", stderr)
            return
        }
        let segments = BriefPlan.resolve(settings().brief?.segments)
        let text = BriefPlan.compose(segments.compactMap { gathered[$0] })
        guard !text.isEmpty else {
            Earcon.error()
            announce("Nothing to brief.")
            return
        }
        fputs("[brief] speaking \(gathered.count) segments, "
            + "\(text.count) chars\n", stderr)
        startRead(text)
    }

    // MARK: - Gathering (all off-main, concurrent, deadlined)

    private func gather(_ segments: [BriefSegment], config: MardukConfig,
                        completion: @escaping ([BriefSegment: String]) -> Void) {
        let box = ResultBox()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        let started = Date()

        for segment in segments {
            group.enter()
            queue.async { [weak self] in
                let text = self?.text(for: segment, config: config) ?? ""
                if !text.isEmpty { box.set(segment, text) }
                group.leave()
            }
        }

        // Whichever comes first wins; `box.claim()` makes that safe to
        // race, so a service that never answers costs the brief its
        // segment and nothing else.
        var finished = false
        let deliver: () -> Void = {
            guard !finished else { return }
            finished = true
            let results = box.claim()
            let missing = segments.count - results.count
            fputs("[brief] gathered \(results.count)/\(segments.count) "
                + "segments in \(Int(Date().timeIntervalSince(started)))s"
                + (missing > 0 ? " (\(missing) empty or timed out)" : "")
                + "\n", stderr)
            completion(results)
        }
        group.notify(queue: .main, execute: deliver)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.gatherDeadline) {
            if !finished { fputs("[brief] gather deadline reached\n", stderr) }
            deliver()
        }
    }

    /// Results shared between the workers and the deadline. A lock, not a
    /// serial queue: the deadline path must be able to READ it from main
    /// while workers are still writing.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [BriefSegment: String] = [:]

        func set(_ segment: BriefSegment, _ text: String) {
            lock.lock(); storage[segment] = text; lock.unlock()
        }

        func claim() -> [BriefSegment: String] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

    // MARK: - The segment table
    //
    // One case per segment, each returning its finished paragraph or the
    // honest "not set up" line. A new segment is a case here plus a case
    // in BriefSegment — never a new code path in the runner above.

    private func text(for segment: BriefSegment,
                      config: MardukConfig) -> String {
        switch segment {
        case .date:
            return BriefPlan.dateLine(Date())
        case .moon:
            return MoonPhase.spoken(at: Date())
        case .weather:
            return weatherText(config.brief)
        case .note:
            return noteText(config.brief)
        case .stocks:
            return stocksText()
        case .news:
            return newsText(config)
        case .horoscope:
            return horoscopeText(config)
        }
    }

    // MARK: - weather

    private func weatherText(_ brief: MardukConfig.BriefConfig?) -> String {
        guard let latitude = brief?.latitude, let longitude = brief?.longitude
        else { return BriefPlan.unconfigured(.weather) }
        let url = Weather.forecastURL(latitude: latitude, longitude: longitude,
                                      metric: brief?.metric ?? false)
        guard let data = Self.fetch(url: url),
              let report = Weather.parse(forecastJSON: data) else {
            fputs("[brief] weather fetch failed\n", stderr)
            return "Couldn't reach the weather service."
        }
        return Weather.spoken(report, place: brief?.place)
    }

    /// `:config place` — geocode a city to coordinates through the same
    /// keyless service, so nobody has to speak a decimal coordinate.
    /// Off-main; the completion lands on main.
    static func geocode(_ query: String,
                        completion: @escaping (Weather.Place?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let data = fetch(url: Weather.geocodeURL(query: query))
            let place = data.flatMap { Weather.parse(geocodingJSON: $0) }
            fputs("[brief] geocode \(place == nil ? "found nothing" : "resolved")"
                + "\n", stderr)
            DispatchQueue.main.async { completion(place) }
        }
    }

    /// curl, the release-check pattern: a Process with its own hard
    /// timeout rather than URLSession, so nothing can outlive the brief.
    /// Never called on main.
    static func fetch(url: String) -> Data? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = ["-s", "-L", "-m", "\(webTimeout)", url]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    // MARK: - note (Notes.app, by title)

    private func noteText(_ brief: MardukConfig.BriefConfig?) -> String {
        guard let title = brief?.noteTitle, !title.isEmpty else {
            return BriefPlan.unconfigured(.note)
        }
        let result = Self.runAppleScript(NotesNote.script(matching: title))
        guard let output = result.output else {
            if NotesNote.automationDenied(result.errors) {
                fputs("[brief] Notes automation denied\n", stderr)
                return "Marduk needs permission to read Notes. Allow it in "
                    + "Settings, Privacy and Security, Automation."
            }
            fputs("[brief] Notes lookup failed\n", stderr)
            return "Couldn't read Notes."
        }
        guard let note = NotesNote.split(reply: output) else {
            fputs("[brief] no note matched the title\n", stderr)
            return "No note matches your brief note title."
        }
        return BriefPlan.noteParagraph(
            title: note.title, body: NotesNote.text(fromHTML: note.html))
    }

    /// osascript with the standard kill-on-timeout watchdog (the
    /// ducker/inverter rule: a hung Apple Event must never wedge a queue).
    /// Never called on main. `output` nil = it failed; `errors` carries
    /// stderr so a refused Automation grant can be named.
    ///
    /// The pipes are drained on their OWN queues, which is what makes the
    /// watchdog real. `readDataToEndOfFile` blocks until the child exits,
    /// so reading inline would mean the timeout loop never ran and a hung
    /// Apple Event would hold the segment forever — while reading only
    /// AFTER the wait would deadlock the other way round, as soon as a
    /// note body filled the 64K pipe buffer. Both hazards are real here:
    /// notes are arbitrarily long and Notes.app can hang on a first-run
    /// Automation prompt.
    static func runAppleScript(_ script: String)
        -> (output: String?, errors: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do { try task.run() } catch { return (nil, "") }

        let outBox = DataBox()
        let errBox = DataBox()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            outBox.set(out.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.set(err.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        let deadline = Date().addingTimeInterval(notesTimeout)
        while task.isRunning, Date() < deadline { usleep(100_000) }
        var timedOut = false
        if task.isRunning {
            task.terminate()
            timedOut = true
            fputs("[brief] osascript timed out — killed\n", stderr)
        }
        // Killing the child closes the pipes, so the readers finish; the
        // wait is bounded anyway rather than trusting that.
        _ = readers.wait(timeout: .now() + 2)
        let errors = String(data: errBox.data, encoding: .utf8) ?? ""
        guard !timedOut, task.terminationStatus == 0 else { return (nil, errors) }
        return (String(data: outBox.data, encoding: .utf8) ?? "", errors)
    }

    /// A `Data` handed between the reader queues and the caller. The
    /// group wait is the happens-before edge; the lock is what makes the
    /// hand-off legal on its own terms.
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()
        func set(_ data: Data) { lock.lock(); value = data; lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return value }
    }

    // MARK: - stocks

    private func stocksText() -> String {
        let watchlist = StockWatchlist.load(from: StocksReader.fileURL)
        var quotes: [String: StockQuote] = [:]
        for entry in watchlist.tickers {
            if let quote = StocksReader.fetchQuote(entry.symbol) {
                quotes[entry.symbol] = quote
            }
        }
        fputs("[brief] quotes \(quotes.count)/\(watchlist.tickers.count)\n",
              stderr)
        return BriefPlan.stocksParagraph(entries: watchlist.tickers,
                                         quotes: quotes)
    }

    // MARK: - news / horoscope (the newsboat cache, read-only)

    /// Resolve newsboat's environment exactly as NEWS mode does, so the
    /// brief reads the same feeds the `n` key browses — including a
    /// Marduk-scoped private instance.
    private func newsboatDB(_ config: MardukConfig) -> NewsboatDB? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let env = NewsboatLocator.resolve(
            command: config.news?.command,
            urlsOverride: config.news?.urlsFile,
            cacheOverride: config.news?.cacheFile,
            configOverride: config.news?.configFile,
            home: home,
            fileExists: { FileManager.default.fileExists(atPath: $0) })
        return NewsboatDB(path: env.cacheFile)
    }

    private func newsText(_ config: MardukConfig) -> String {
        guard let db = newsboatDB(config) else {
            return BriefPlan.unconfigured(.news)
        }
        let wanted = config.brief?.headlines ?? BriefPlan.defaultHeadlines
        let unread = db.unreadCounts().values.reduce(0, +)
        let headlines = wanted > 0
            ? db.unreadItems(limit: wanted).map(\.title)
            : []
        fputs("[brief] news: \(unread) unread, \(headlines.count) headlines\n",
              stderr)
        return BriefPlan.newsParagraph(unread: unread, headlines: headlines)
    }

    /// The horoscope rides the news store rather than a horoscope API:
    /// the free ones are unreliable and would be a second network
    /// dependency for a novelty segment, while an RSS horoscope is a feed
    /// the user already knows how to add. `brief.horoscopeFeed` matches
    /// part of the feed's title or address, case-insensitively.
    private func horoscopeText(_ config: MardukConfig) -> String {
        guard let match = config.brief?.horoscopeFeed, !match.isEmpty,
              let db = newsboatDB(config) else {
            return BriefPlan.unconfigured(.horoscope)
        }
        let needle = match.lowercased()
        let feedURL = db.feedTitles().first {
            $0.value.lowercased().contains(needle)
                || $0.key.lowercased().contains(needle)
        }?.key
        guard let feedURL, let newest = db.articles(feedURL: feedURL).first
        else {
            fputs("[brief] horoscope feed matched nothing\n", stderr)
            return "No horoscope feed matches that name."
        }
        let body = db.content(id: newest.id).map { NewsHTML.text(from: $0) } ?? ""
        let paragraph = BriefPlan.horoscopeParagraph(
            body: body.isEmpty ? newest.title : body)
        return paragraph.isEmpty ? "The horoscope feed has nothing today."
                                 : paragraph
    }
}
