import Foundation

/// STOCKS mode (`S`): a spoken watchlist with alert levels. Unlike NEWS
/// there is no external app to mirror — the list is Marduk's own, so
/// keys never post anywhere and the only state is the file and the
/// cursor. Quotes come per symbol from Yahoo's keyless v8 chart endpoint
/// via curl (the release-check pattern: Process + timeout, off-main);
/// every fetch also runs the trigger check, and crossings are spoken
/// once per transition. Symbols are normalized to a URL-safe charset
/// before they ever reach a command line.
final class StocksReader {

    // Wired by the daemon
    var announce: (String) -> Void = { _ in }
    var setCaptured: (Bool) -> Void = { _ in }
    var openCommandLine: (String) -> Void = { _ in }
    // The TUI panel: shown while the mode is open, updated on every state
    // change, hidden on exit. Display only — the voice stays primary.
    var showDisplay: ([StocksPanel.Row]) -> Void = { _ in }
    var hideDisplay: () -> Void = {}

    static let helpLine = "j and k move. r speaks the detail. a adds a "
        + "ticker. d d removes it. b sets a buy alert, s a sell alert. "
        + "Escape leaves."

    private(set) var active = false
    private var session = StockSession()
    private var watchlist = StockWatchlist()
    private var quotes: [String: StockQuote] = [:]
    private var beyond: [String: StockTriggers.Beyond] = [:]
    private var lastFetch = Date.distantPast
    private var fetchGeneration = 0

    static var fileURL: URL {
        ConfigLoader.configDir.appendingPathComponent("stocks.json")
    }

    // MARK: - Entry / exit

    func enter() {
        guard !active else {
            announce("Stocks is already open.")
            return
        }
        watchlist = StockWatchlist.load(from: Self.fileURL)
        session.sync(to: watchlist.tickers.map(\.symbol), keep: nil)
        session.index = 0
        active = true
        setCaptured(true)
        fputs("[stocks] open — \(session.symbols.count) tickers\n", stderr)
        showDisplay(displayRows())
        if session.symbols.isEmpty {
            announce("Your watchlist is empty. Press a to add a ticker."
                + (OnceMarker.firstTime("stocks-hinted") ? " " + Self.helpLine : ""))
            return
        }
        // Straight into the first row (the news-mode ruling: no count
        // preamble); the quote lands when the fetch does.
        var line = currentLine()
        if OnceMarker.firstTime("stocks-hinted") { line += " " + Self.helpLine }
        announce(line)
        refresh(speakCurrentAfter: quotes[session.current ?? ""] == nil)
    }

    func handle(_ command: StocksCommand) {
        if case .exit = command {
            deactivate()
            return
        }
        guard active else { return }
        switch command {
        case .move(let delta):
            if session.move(delta) == 0 { Earcon.error() } else { speakCurrent() }
            showDisplay(displayRows())
            refresh(speakCurrentAfter: false)
        case .top:
            if session.move(-session.symbols.count) == 0 { Earcon.error() }
            else { speakCurrent() }
            showDisplay(displayRows())
        case .bottom:
            if session.move(session.symbols.count) == 0 { Earcon.error() }
            else { speakCurrent() }
            showDisplay(displayRows())
        case .detail:
            guard let symbol = session.current else { Earcon.error(); return }
            if let quote = quotes[symbol] {
                announce(quote.detail + triggerSuffix(symbol))
            } else {
                announce("\(symbol). No quote yet.")
                refresh(speakCurrentAfter: false)
            }
        case .add:
            openCommandLine("stock add ")
        case .remove:
            guard let symbol = session.current else { Earcon.error(); return }
            execute(.remove(symbol))
        case .buyTrigger:
            guard let symbol = session.current else { Earcon.error(); return }
            openCommandLine("stock buy \(symbol.lowercased()) ")
        case .sellTrigger:
            guard let symbol = session.current else { Earcon.error(); return }
            openCommandLine("stock sell \(symbol.lowercased()) ")
        case .help:
            announce(Self.helpLine)
        case .exit:
            break
        }
    }

    func deactivate() {
        guard active else { return }
        active = false
        setCaptured(false)
        hideDisplay()
        fetchGeneration += 1  // drop an in-flight fetch's announcements
        fputs("[stocks] closed\n", stderr)
    }

    /// A click on a panel row — move the spoken cursor there.
    func selectRow(_ index: Int) {
        guard active, session.symbols.indices.contains(index) else { return }
        session.index = index
        speakCurrent()
        showDisplay(displayRows())
    }

    // MARK: - Panel rows

    private func displayRows() -> [StocksPanel.Row] {
        watchlist.tickers.enumerated().map { index, entry in
            let quote = quotes[entry.symbol]
            var alerts: [String] = []
            if let buy = entry.buyBelow {
                alerts.append("↓\(StockQuote.spokenPrice(buy))")
            }
            if let sell = entry.sellAbove {
                alerts.append("↑\(StockQuote.spokenPrice(sell))")
            }
            let percent = quote?.changePercent
            let change = percent.map {
                String(format: "%+.1f%%", $0)
            } ?? ""
            return StocksPanel.Row(
                symbol: entry.symbol,
                price: quote.map { StockQuote.spokenPrice($0.price) } ?? "…",
                change: change,
                alerts: alerts.joined(separator: " "),
                current: index == session.index)
        }
    }

    // MARK: - Colon commands (:stock …) — work with or without the mode open

    func execute(_ command: StockColonCommand) {
        watchlist = StockWatchlist.load(from: Self.fileURL)
        switch command {
        case .list:
            guard !watchlist.tickers.isEmpty else {
                announce("Your watchlist is empty. Say colon stock add, "
                    + "then a ticker symbol.")
                return
            }
            let symbols = watchlist.tickers.map(\.symbol)
            announce("Watching \(symbols.joined(separator: ", ")). "
                + "Press capital S to browse.")
        case .add(let symbol):
            guard watchlist.add(symbol) else {
                announce("\(symbol) is already on the watchlist.")
                return
            }
            watchlist.save(to: Self.fileURL)
            syncSession(keep: symbol)
            announce("Added \(symbol).")
            refresh(speakCurrentAfter: false)
        case .remove(let symbol):
            guard watchlist.remove(symbol) else {
                Earcon.error()
                announce("\(symbol) isn't on the watchlist.")
                return
            }
            watchlist.save(to: Self.fileURL)
            quotes[symbol] = nil
            beyond[symbol] = nil
            syncSession(keep: nil)
            announce("Removed \(symbol).")
        case .trigger(let symbol, let side, let level):
            guard watchlist.setTrigger(symbol, side: side, level: level) else {
                Earcon.error()
                announce("\(symbol) isn't on the watchlist. Add it first.")
                return
            }
            watchlist.save(to: Self.fileURL)
            beyond[symbol] = nil  // re-arm: a fresh level gets a fresh crossing
            refreshDisplay()
            let word = side == .buy ? "Buy alert" : "Sell alert"
            if let level {
                announce("\(word) for \(symbol) at \(StockQuote.spokenPrice(level)).")
                refresh(speakCurrentAfter: false)
            } else {
                announce("\(word) for \(symbol) cleared.")
            }
        case .unknown(let raw):
            Earcon.error()
            announce(raw.isEmpty
                ? "Stock takes add, remove, buy, or sell — like colon stock "
                    + "add A A P L, or colon stock buy A A P L 180."
                : "Couldn't parse stock \(raw). Say colon stock add, remove, "
                    + "buy, or sell.")
        }
    }

    private func syncSession(keep: String?) {
        let held = keep ?? session.current
        session.sync(to: watchlist.tickers.map(\.symbol), keep: held)
        refreshDisplay()
    }

    private func refreshDisplay() {
        if active { showDisplay(displayRows()) }
    }

    // MARK: - Speech

    private func speakCurrent() {
        announce(currentLine())
    }

    private func currentLine() -> String {
        guard let symbol = session.current else { return "No tickers." }
        guard let quote = quotes[symbol] else { return "\(symbol), no quote yet" }
        return quote.line
    }

    private func triggerSuffix(_ symbol: String) -> String {
        guard let entry = watchlist.entry(symbol) else { return "" }
        var parts: [String] = []
        if let buy = entry.buyBelow {
            parts.append("Buy alert \(StockQuote.spokenPrice(buy))")
        }
        if let sell = entry.sellAbove {
            parts.append("sell alert \(StockQuote.spokenPrice(sell))")
        }
        return parts.isEmpty ? "" : " " + parts.joined(separator: ", ") + "."
    }

    // MARK: - Quotes (keyless Yahoo v8 chart, curl per symbol, off-main)

    private static let quoteUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15"

    /// Refresh at most every 30s. Runs the trigger check on arrival;
    /// optionally re-speaks the current row once its first quote lands.
    private func refresh(speakCurrentAfter: Bool) {
        guard Date().timeIntervalSince(lastFetch) > 30 || speakCurrentAfter else {
            return
        }
        let symbols = watchlist.tickers.map(\.symbol)
        guard !symbols.isEmpty else { return }
        lastFetch = Date()
        fetchGeneration += 1
        let generation = fetchGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var fetched: [String: StockQuote] = [:]
            for symbol in symbols {
                if let quote = Self.fetchQuote(symbol) { fetched[symbol] = quote }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.fetchGeneration else { return }
                self.quotesArrived(fetched, speakCurrent: speakCurrentAfter)
            }
        }
    }

    private func quotesArrived(_ fetched: [String: StockQuote], speakCurrent: Bool) {
        let hadCurrent = session.current.flatMap { quotes[$0] } != nil
        quotes.merge(fetched) { _, new in new }
        refreshDisplay()
        fputs("[stocks] quotes: \(fetched.count)/\(watchlist.tickers.count)\n",
              stderr)
        var lines: [String] = []
        for entry in watchlist.tickers {
            guard let quote = fetched[entry.symbol] else { continue }
            let result = StockTriggers.check(
                entry: entry, price: quote.price,
                wasBeyond: beyond[entry.symbol] ?? StockTriggers.Beyond())
            beyond[entry.symbol] = result.beyond
            lines.append(contentsOf: result.events.map(\.spoken))
        }
        if speakCurrent, !hadCurrent, active { lines.insert(currentLine(), at: 0) }
        if !lines.isEmpty, active {
            announce(lines.joined(separator: " "))
        }
    }

    private static func fetchQuote(_ symbol: String) -> StockQuote? {
        let url = "https://query1.finance.yahoo.com/v8/finance/chart/"
            + symbol + "?range=1d&interval=1d"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = ["-s", "-L", "-m", "8", "-A", quoteUserAgent, url]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return StockQuote.parse(chartJSON: data)
    }
}
