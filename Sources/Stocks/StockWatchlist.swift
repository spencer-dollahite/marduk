import Foundation

/// One watched ticker with optional alert levels. Buy/sell triggers are
/// SPOKEN ALERTS only — Marduk announces a crossing, it never trades.
struct StockEntry: Codable, Equatable {
    var symbol: String
    var buyBelow: Double?
    var sellAbove: Double?
}

/// The persisted watchlist: ~/.config/marduk/stocks.json — user DATA, so
/// it lives beside config.json rather than inside it (hand-editable, and
/// a decode failure must never threaten voice/rate settings).
struct StockWatchlist: Codable, Equatable {
    var tickers: [StockEntry] = []

    /// Uppercased ticker restricted to the charset quote symbols use —
    /// also what makes the symbol safe to embed in a quote URL. Nil = not
    /// a ticker shape.
    static func normalize(_ raw: String) -> String? {
        let symbol = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard !symbol.isEmpty, symbol.count <= 12,
              symbol.allSatisfy({ $0.isLetter || $0.isNumber
                  || $0 == "." || $0 == "-" || $0 == "^" || $0 == "=" }) else {
            return nil
        }
        return symbol
    }

    func entry(_ symbol: String) -> StockEntry? {
        tickers.first { $0.symbol == symbol }
    }

    /// False = already present.
    mutating func add(_ symbol: String) -> Bool {
        guard entry(symbol) == nil else { return false }
        tickers.append(StockEntry(symbol: symbol))
        return true
    }

    /// False = wasn't there.
    mutating func remove(_ symbol: String) -> Bool {
        let before = tickers.count
        tickers.removeAll { $0.symbol == symbol }
        return tickers.count != before
    }

    /// Set (or clear, level nil) an alert. False = unknown symbol.
    mutating func setTrigger(_ symbol: String, side: TriggerSide,
                             level: Double?) -> Bool {
        guard let index = tickers.firstIndex(where: { $0.symbol == symbol }) else {
            return false
        }
        switch side {
        case .buy: tickers[index].buyBelow = level
        case .sell: tickers[index].sellAbove = level
        }
        return true
    }

    static func load(from url: URL) -> StockWatchlist {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode(StockWatchlist.self, from: data)
        else { return StockWatchlist() }
        return list
    }

    func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (try? encoder.encode(self))?.write(to: url, options: .atomic)
    }
}

/// A fetched quote (Yahoo v8 chart metadata — keyless, per symbol).
struct StockQuote: Equatable {
    var symbol: String
    var name: String?
    var price: Double
    var previousClose: Double?
    var dayHigh: Double?
    var dayLow: Double?

    var changePercent: Double? {
        guard let previousClose, previousClose != 0 else { return nil }
        return (price - previousClose) / previousClose * 100
    }

    /// chart.result[0].meta of Yahoo's v8 chart response.
    static func parse(chartJSON data: Data) -> StockQuote? {
        guard let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let chart = root["chart"] as? [String: Any],
              let result = (chart["result"] as? [[String: Any]])?.first,
              let meta = result["meta"] as? [String: Any],
              let symbol = meta["symbol"] as? String,
              let price = number(meta["regularMarketPrice"]) else {
            return nil
        }
        return StockQuote(
            symbol: symbol,
            name: (meta["shortName"] as? String) ?? (meta["longName"] as? String),
            price: price,
            previousClose: number(meta["previousClose"])
                ?? number(meta["chartPreviousClose"]),
            dayHigh: number(meta["regularMarketDayHigh"]),
            dayLow: number(meta["regularMarketDayLow"]))
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    /// "309.86" — two decimals, whole prices bare ("180").
    static func spokenPrice(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 100_000
            ? String(Int(value.rounded()))
            : String(format: "%.2f", value)
    }

    /// "up 1.2 percent" / "down 0.8 percent" / "flat".
    static func spokenChange(_ percent: Double?) -> String {
        guard let percent else { return "" }
        let magnitude = abs(percent)
        if magnitude < 0.05 { return "flat" }
        let word = percent > 0 ? "up" : "down"
        return "\(word) \(String(format: "%.1f", magnitude)) percent"
    }

    /// The j/k row: "AAPL, 309.86, up 1.2 percent" — minimal verbosity.
    var line: String {
        let change = Self.spokenChange(changePercent)
        return change.isEmpty
            ? "\(symbol), \(Self.spokenPrice(price))"
            : "\(symbol), \(Self.spokenPrice(price)), \(change)"
    }

    /// The r detail: name, price, change, range, previous close.
    var detail: String {
        var parts: [String] = []
        parts.append("\(name ?? symbol). \(Self.spokenPrice(price))")
        let change = Self.spokenChange(changePercent)
        if !change.isEmpty { parts.append(change + " today") }
        if let dayLow, let dayHigh {
            parts.append("day range \(Self.spokenPrice(dayLow)) to "
                + Self.spokenPrice(dayHigh))
        }
        if let previousClose {
            parts.append("previous close \(Self.spokenPrice(previousClose))")
        }
        return parts.joined(separator: ". ") + "."
    }
}

enum TriggerSide: String, Codable { case buy, sell }

/// A tripped alert, ready to speak.
struct TriggerEvent: Equatable {
    let symbol: String
    let side: TriggerSide
    let level: Double
    let price: Double

    var spoken: String {
        let direction = side == .buy ? "below your buy level"
                                     : "above your sell level"
        return "\(symbol) is \(direction) \(StockQuote.spokenPrice(level)): "
            + "\(StockQuote.spokenPrice(price))."
    }
}

/// Pure crossing logic: an alert fires on the TRANSITION into its region,
/// never on every refresh while the price sits there (`wasBeyond` is the
/// previous refresh's answer, per side).
enum StockTriggers {
    struct Beyond: Equatable {
        var buy = false
        var sell = false
    }

    static func check(entry: StockEntry, price: Double,
                      wasBeyond: Beyond) -> (events: [TriggerEvent], beyond: Beyond) {
        var beyond = Beyond()
        var events: [TriggerEvent] = []
        if let level = entry.buyBelow {
            beyond.buy = price <= level
            if beyond.buy, !wasBeyond.buy {
                events.append(TriggerEvent(symbol: entry.symbol, side: .buy,
                                           level: level, price: price))
            }
        }
        if let level = entry.sellAbove {
            beyond.sell = price >= level
            if beyond.sell, !wasBeyond.sell {
                events.append(TriggerEvent(symbol: entry.symbol, side: .sell,
                                           level: level, price: price))
            }
        }
        return (events, beyond)
    }
}
