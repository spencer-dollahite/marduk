import Foundation

/// One line of the DAILY BRIEF (`d`): a spoken morning rundown assembled
/// from sources Marduk already owns. Segments are a TABLE, never a code
/// path — a new segment is a case here plus its gatherer in
/// `BriefReader`, and the user toggles/orders them with the `:segments`
/// picker (order follows this declaration; hand-edits to
/// `brief.segments` in config.json may reorder freely).
///
/// Everything here is PURE — composition, wording, and the segment
/// table — so the whole shape of a brief is testable without a Mac, a
/// network, or a Notes database. The impure half (curl, osascript,
/// SQLite) lives in `BriefReader`.
enum BriefSegment: String, CaseIterable {
    case date       // "Friday, 22 August. The time is oh 8 07."
    case weather    // open-meteo, keyless (see Weather)
    case note       // a note in Notes.app, matched by title
    case stocks     // the `S` watchlist, with any levels already crossed
    case news       // the newsboat cache's newest unread headlines
    case moon       // pure astronomy, no network (off by default)
    case horoscope  // a feed already in newsboat (off by default)

    /// Spoken in the `:segments` picker. Never the raw case name — these
    /// rows are read aloud.
    var spokenName: String {
        switch self {
        case .date: return "date and time"
        case .weather: return "weather"
        case .note: return "your note"
        case .stocks: return "stock watchlist"
        case .news: return "news headlines"
        case .moon: return "moon phase"
        case .horoscope: return "horoscope"
        }
    }
}

enum BriefPlan {

    /// What a brief holds before the user touches anything. Moon and
    /// horoscope are deliberately OUT (user ruling 2026-08-04: extras are
    /// opt-in) — `:segments` turns them on.
    static let defaultSegments: [BriefSegment] = [.date, .weather, .note,
                                                  .stocks, .news]

    /// Longest note (or horoscope) body the brief will speak. A brief is
    /// a rundown, not an audiobook: a title match that lands on a huge
    /// note must not hijack the whole thing. Uppercase R on the note
    /// itself is the unbounded read.
    static let bodyCharLimit = 2000

    /// How many headlines the news segment speaks when the config says
    /// nothing.
    static let defaultHeadlines = 5

    // MARK: - The segment list

    /// Config → segments. Unknown ids are DROPPED rather than failing the
    /// brief (a hand-edited config.json with a typo still runs), and
    /// duplicates collapse. Nil (never configured) means the defaults;
    /// an EMPTY array is a real choice and stays empty.
    static func resolve(_ raw: [String]?) -> [BriefSegment] {
        guard let raw else { return defaultSegments }
        var seen = Set<BriefSegment>()
        return raw.compactMap { BriefSegment(rawValue: $0.lowercased()) }
            .filter { seen.insert($0).inserted }
    }

    /// The `:segments` picker's Return: one row toggles in or out. Turning
    /// a segment ON inserts it at its CANONICAL position rather than
    /// appending, so the brief keeps a sensible running order without the
    /// user having to think about it.
    static func toggle(_ current: [BriefSegment],
                       _ segment: BriefSegment) -> [BriefSegment] {
        if current.contains(segment) {
            return current.filter { $0 != segment }
        }
        let canonical = BriefSegment.allCases
        var result = current
        let rank = canonical.firstIndex(of: segment) ?? canonical.count
        let insertAt = result.firstIndex {
            (canonical.firstIndex(of: $0) ?? canonical.count) > rank
        } ?? result.count
        result.insert(segment, at: insertAt)
        return result
    }

    /// The picker's rows: every segment, said as words, with whether it is
    /// in. Spoken, so it says "included", never a checkbox.
    static func pickerRows(_ current: [BriefSegment])
        -> [(name: String, identifier: String)] {
        BriefSegment.allCases.map {
            (name: "\($0.spokenName) — "
                + (current.contains($0) ? "included" : "not included"),
             identifier: $0.rawValue)
        }
    }

    // MARK: - Composition

    /// Segments become PARAGRAPHS — blank-line separated, which is exactly
    /// what the reader's `{` and `}` motions step over. So the brief is
    /// skimmable: `}` jumps past the weather to the headlines, and every
    /// other reading motion (search, pause, replay) applies, because the
    /// brief is a READ and not a status announcement.
    static func compose(_ parts: [String]) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Trim a body to `bodyCharLimit`, cutting at a word boundary and
    /// SAYING that it was cut — silently swallowing the rest would read as
    /// a note that just ends.
    static func clamp(body: String, limit: Int = bodyCharLimit) -> String {
        guard body.count > limit else { return body }
        let head = String(body.prefix(limit))
        let cut = head.lastIndex(where: { $0 == " " || $0 == "\n" })
            .map { String(head[head.startIndex..<$0]) } ?? head
        return cut + "… That note continues."
    }

    // MARK: - date

    /// The clock, spoken the way `t` says it (24-hour, "oh" for a leading
    /// zero, "hundred" on the hour). Pure and shared: `KeyboardMonitor`
    /// calls this too, so `t` and the brief can never drift apart.
    static func spokenClock(hour: Int, minute: Int) -> String {
        let hourPart = hour < 10 ? "oh \(hour)" : "\(hour)"
        let minutePart: String
        if minute == 0 {
            minutePart = "hundred"
        } else if minute < 10 {
            minutePart = "oh \(minute)"
        } else {
            minutePart = "\(minute)"
        }
        return "\(hourPart) \(minutePart)"
    }

    /// "Friday, 22 August. The time is oh 8 07."
    ///
    /// The formatter is pinned to en_US_POSIX: every spoken string in this
    /// product is English, and a locale-dependent weekday would make this
    /// untestable as well as inconsistent with the rest of the voice.
    static func dateLine(_ now: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, d MMMM"
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        return "\(formatter.string(from: now)). The time is "
            + "\(spokenClock(hour: hour, minute: minute))."
    }

    // MARK: - stocks

    /// The watchlist paragraph: every ticker's row, then any level the
    /// price is ALREADY past. Deliberately NOT `StockTriggers` — those
    /// fire on the transition into a region and are stateful; a brief
    /// reports the state of the world as it is this morning, so a level
    /// crossed overnight is still worth saying.
    static func stocksParagraph(entries: [StockEntry],
                                quotes: [String: StockQuote]) -> String {
        guard !entries.isEmpty else {
            return "Your stock watchlist is empty. Press capital S to add "
                + "tickers."
        }
        var lines = ["Watchlist."]
        var alerts: [String] = []
        for entry in entries {
            guard let quote = quotes[entry.symbol] else {
                lines.append("\(entry.symbol), no quote.")
                continue
            }
            lines.append(quote.line + ".")
            if let alert = alertLine(entry, quote) { alerts.append(alert) }
        }
        return (lines + alerts).joined(separator: " ")
    }

    /// A level the price is currently beyond, said in the quote's own
    /// unit. Nil = nothing to report.
    static func alertLine(_ entry: StockEntry, _ quote: StockQuote) -> String? {
        if let level = entry.buyBelow, quote.price <= level {
            return "\(entry.symbol) is below your buy level of "
                + "\(quote.amount(level))."
        }
        if let level = entry.sellAbove, quote.price >= level {
            return "\(entry.symbol) is above your sell level of "
                + "\(quote.amount(level))."
        }
        return nil
    }

    // MARK: - news

    /// "News. 42 unread. <title>. <title>." — counts first, because that
    /// is the number a user acts on; the headlines are the sample.
    static func newsParagraph(unread: Int, headlines: [String]) -> String {
        guard unread > 0 else { return "News. Nothing unread." }
        let head = "News. \(unread) unread."
        guard !headlines.isEmpty else { return head }
        return ([head] + headlines.map { titleSentence($0) })
            .joined(separator: " ")
    }

    /// Headlines rarely end in punctuation, and without a full stop the
    /// voice runs two of them together.
    static func titleSentence(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }

    // MARK: - note / horoscope

    /// "Your note, Groceries. Milk, eggs." — the note's own name is spoken
    /// so a title that matched something unexpected is obvious.
    static func noteParagraph(title: String, body: String) -> String {
        let body = clamp(body: body.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !body.isEmpty else {
            return "Your note, \(title), is empty."
        }
        return "Your note, \(title). \(body)"
    }

    static func horoscopeParagraph(body: String) -> String {
        let body = clamp(body: body.trimmingCharacters(in: .whitespacesAndNewlines))
        return body.isEmpty ? "" : "Horoscope. \(body)"
    }

    // MARK: - Honest degradation

    /// What a segment says when its source isn't set up. Every one names
    /// the command that fixes it — a brief that just skipped the weather
    /// would leave the user with no way to find out why (and `:segments`
    /// turns a segment the user doesn't want off for good).
    static func unconfigured(_ segment: BriefSegment) -> String {
        switch segment {
        case .weather:
            return "Weather is not set up. Say colon config place, then your "
                + "city."
        case .note:
            return "No brief note yet. Say colon config note, then the title "
                + "of a note in Notes."
        case .horoscope:
            return "The horoscope needs a feed. Add one to newsboat, then say "
                + "colon config horoscope, then part of its name."
        case .news:
            return "News is not set up. It reads your newsboat feeds — press "
                + "n to set them up."
        case .date, .stocks, .moon:
            return ""   // these have no configuration to be missing
        }
    }
}
