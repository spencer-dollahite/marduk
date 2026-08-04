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
    var currency: String?        // "USD", "EUR", … — drives the spoken unit
    var instrumentType: String?  // "EQUITY"/"ETF"/"INDEX"/… — indexes are
                                 // POINTS, never dollars

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
            dayLow: number(meta["regularMarketDayLow"]),
            currency: meta["currency"] as? String,
            instrumentType: meta["instrumentType"] as? String)
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

    /// Spoken currency units, keyed by Yahoo's currency code. Instruments
    /// that aren't priced in money (indexes, FX rates, crypto pairs)
    /// speak the bare number instead — "the S and P at 6300 dollars"
    /// would be wrong, index points aren't money.
    private static let currencyWords: [String: (major: String, minor: String?)] = [
        "USD": ("dollars", "cents"),
        "CAD": ("Canadian dollars", "cents"),
        "AUD": ("Australian dollars", "cents"),
        "EUR": ("euros", "cents"),
        "GBP": ("pounds", "pence"),
        "GBp": ("pence", nil),   // London quotes in pence-sterling
        "JPY": ("yen", nil),
    ]

    private static let moneyless: Set<String> = [
        "INDEX", "CURRENCY", "CRYPTOCURRENCY",
    ]

    /// A price as SPEECH: "309 dollars 86 cents", "180 dollars", or the
    /// bare number for point-valued instruments and unknown units.
    static func spokenAmount(_ value: Double, currency: String?,
                             instrumentType: String?) -> String {
        if let type = instrumentType, moneyless.contains(type) {
            return spokenPrice(value)
        }
        guard let unit = currencyWords[currency ?? "USD"] else {
            // Unknown currency: number + its code, spelled by the voice
            return "\(spokenPrice(value)) \(currency ?? "")"
                .trimmingCharacters(in: .whitespaces)
        }
        var whole = Int(value.rounded(.down))
        guard let minor = unit.minor else {
            return "\(spokenPrice(value)) \(unit.major)"
        }
        var cents = Int(((value - Double(whole)) * 100).rounded())
        if cents == 100 { whole += 1; cents = 0 }  // 179.999 rounds up clean
        return cents == 0
            ? "\(whole) \(unit.major)"
            : "\(whole) \(unit.major) \(cents) \(minor)"
    }

    /// This quote's own unit applied to any value (trigger levels, ranges).
    func amount(_ value: Double) -> String {
        Self.spokenAmount(value, currency: currency, instrumentType: instrumentType)
    }

    /// "up 1.2 percent" / "down 0.8 percent" / "flat".
    static func spokenChange(_ percent: Double?) -> String {
        guard let percent else { return "" }
        let magnitude = abs(percent)
        if magnitude < 0.05 { return "flat" }
        let word = percent > 0 ? "up" : "down"
        return "\(word) \(String(format: "%.1f", magnitude)) percent"
    }

    /// The j/k row: "AAPL, 309 dollars 86 cents, up 1.2 percent".
    var line: String {
        let change = Self.spokenChange(changePercent)
        return change.isEmpty
            ? "\(symbol), \(amount(price))"
            : "\(symbol), \(amount(price)), \(change)"
    }

    /// The r detail: name, price, change, range, previous close.
    var detail: String {
        var parts: [String] = []
        parts.append("\(name ?? symbol). \(amount(price))")
        let change = Self.spokenChange(changePercent)
        if !change.isEmpty { parts.append(change + " today") }
        if let dayLow, let dayHigh {
            parts.append("day range \(amount(dayLow)) to \(amount(dayHigh))")
        }
        if let previousClose {
            parts.append("previous close \(amount(previousClose))")
        }
        return parts.joined(separator: ". ") + "."
    }
}

enum TriggerSide: String, Codable { case buy, sell }

/// A tripped alert, ready to speak. Carries the quote's unit so the
/// announcement says dollars (or euros, or bare points) correctly.
struct TriggerEvent: Equatable {
    let symbol: String
    let side: TriggerSide
    let level: Double
    let price: Double
    var currency: String?
    var instrumentType: String?

    var spoken: String {
        let direction = side == .buy ? "below your buy level"
                                     : "above your sell level"
        let levelSpoken = StockQuote.spokenAmount(
            level, currency: currency, instrumentType: instrumentType)
        let priceSpoken = StockQuote.spokenAmount(
            price, currency: currency, instrumentType: instrumentType)
        return "\(symbol) is \(direction) \(levelSpoken): \(priceSpoken)."
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
                      wasBeyond: Beyond,
                      currency: String? = nil,
                      instrumentType: String? = nil)
        -> (events: [TriggerEvent], beyond: Beyond) {
        var beyond = Beyond()
        var events: [TriggerEvent] = []
        if let level = entry.buyBelow {
            beyond.buy = price <= level
            if beyond.buy, !wasBeyond.buy {
                events.append(TriggerEvent(symbol: entry.symbol, side: .buy,
                                           level: level, price: price,
                                           currency: currency,
                                           instrumentType: instrumentType))
            }
        }
        if let level = entry.sellAbove {
            beyond.sell = price >= level
            if beyond.sell, !wasBeyond.sell {
                events.append(TriggerEvent(symbol: entry.symbol, side: .sell,
                                           level: level, price: price,
                                           currency: currency,
                                           instrumentType: instrumentType))
            }
        }
        return (events, beyond)
    }
}
