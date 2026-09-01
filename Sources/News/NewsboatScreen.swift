import Foundation

/// WHERE NEWSBOAT IS, read off its own screen.
///
/// The mirror used to ASSUME: every `n` that attached to a running
/// newsboat built a fresh session on the feed list, row 0, wherever the
/// TUI actually was — and after "open an item, switch away, come back"
/// it was routinely in the pager or an article list, so every j/k after
/// that drove one layer while the voice spoke another (field 2026-09-01).
/// newsboat has no IPC, but Terminal exposes its screen text over AX and
/// newsboat's TOP LINE names the dialog it is showing. That line is
/// rendered from the `*-title-format` settings, which the user may (and
/// this user does) override, so the signatures are COMPILED FROM THE
/// EFFECTIVE CONFIG with newsboat's stock formats as the default — the
/// same "the config is the table" pattern as `gotoFirstUnread`.
///
/// Pure: string in, layer out. The AX read lives in NewsReader.
enum NewsboatScreen {
    /// Which dialog the title line belongs to. `articles` carries the feed
    /// title newsboat printed for `%T`, when the format includes one — the
    /// mirror uses it to find the feed, and it is USER CONTENT (never
    /// logged).
    enum Layer: Equatable {
        case feeds
        case articles(feedTitle: String?)
        case pager
        case other(String)   // help, urlview, searchresult, … — q climbs out
    }

    /// One `*-title-format` compiled into a matchable shape.
    struct Signature: Equatable {
        enum Token: Equatable {
            case literal(String)
            case wild        // any specifier — text we can't predict
            case feedTitle   // articlelist's %T — captured
        }
        var key: String      // "feedlist", "articlelist", "itemview", …
        var tokens: [Token]
    }

    /// newsboat's stock title formats (configcontainer.cpp, read
    /// 2026-09-01) — the defaults a config may override.
    static let stockFormats: [String: String] = [
        "feedlist": "%N %V - %?F?Feeds&Your feeds? (%u unread, %t total)"
            + "%?F? matching filter '%F'&?%?T? - tag '%T'&?",
        "articlelist": "%N %V - Articles in feed '%T' (%u unread, %t total)"
            + "%?F? matching filter '%F'&? - %U",
        "itemview": "%N %V - Article '%T' (%u unread, %t total)",
        "searchresult": "%N %V - Search results for '%s' (%u unread, %t total)"
            + "%?F? matching filter '%F'&?",
        "help": "%N %V - Help",
        "urlview": "%N %V - URLs",
        "dialogs": "%N %V - Dialogs",
        "selecttag": "%N %V - Select Tag",
        "selectfilter": "%N %V - Select Filter",
        "filebrowser": "%N %V - %?O?Open File&Save File? - %f",
        "dirbrowser": "%N %V - %?O?Open Directory&Save File? - %f",
    ]

    /// A literal has to earn at least this many characters of agreement
    /// before a line counts as a match — " - " alone (the stock separator)
    /// is not a dialog.
    static let minimumScore = 6

    // MARK: - Config → formats

    /// The effective title formats: the stock table overlaid with every
    /// `<key>-title-format "…"` line in the config. nil config = stock.
    static func titleFormats(configText: String?) -> [String: String] {
        var formats = stockFormats
        guard let configText else { return formats }
        for raw in configText.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"),
                  let space = line.firstIndex(where: { $0 == " " || $0 == "\t" })
            else { continue }
            let setting = String(line[..<space])
            guard setting.hasSuffix("-title-format") else { continue }
            let key = String(setting.dropLast("-title-format".count))
            guard formats[key] != nil else { continue }   // not a dialog we know
            let value = configValue(String(line[space...]))
            guard !value.isEmpty else { continue }
            formats[key] = value
        }
        return formats
    }

    /// A newsboat config value: double-quoted with backslash escapes, or
    /// bare to the end of the line.
    static func configValue(_ tail: String) -> String {
        let trimmed = tail.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\"") else { return trimmed }
        var out = ""
        var escaped = false
        for ch in trimmed.dropFirst() {
            if escaped {
                out.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                break
            } else {
                out.append(ch)
            }
        }
        return out
    }

    // MARK: - Format → signature

    /// Compile one format (newsboat's fmtstr grammar, read from
    /// rust/libnewsboat/src/fmtstrformatter/parser.rs): `%%` is a percent,
    /// `%?c?then&else?` is a conditional (its text may or may not appear,
    /// so it is a wildcard), `%>c` pads, `%=Nc` centers, `%[-][N]x` is a
    /// specifier. Only the articlelist's `%T` is captured — the itemview's
    /// `%T` is the article title, which the mirror doesn't need.
    static func compile(key: String, format: String) -> Signature {
        var tokens: [Signature.Token] = []
        var literal = ""
        func flush() {
            if !literal.isEmpty { tokens.append(.literal(literal)); literal = "" }
        }
        let chars = Array(format)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            guard ch == "%", i + 1 < chars.count else {
                literal.append(ch)
                i += 1
                continue
            }
            let next = chars[i + 1]
            switch next {
            case "%":
                literal.append("%")
                i += 2
            case "?":
                // %?c?then&else? — skip to the closing ? after the branches
                flush()
                tokens.append(.wild)
                var j = i + 2
                if j < chars.count { j += 1 }          // the condition char
                if j < chars.count, chars[j] == "?" { j += 1 }
                while j < chars.count, chars[j] != "?" { j += 1 }
                i = min(j + 1, chars.count)
            case ">":
                flush()
                tokens.append(.wild)
                i += 3                                  // %>c
            case "=":
                flush()
                tokens.append(.wild)
                var j = i + 2
                while j < chars.count, chars[j].isNumber { j += 1 }
                i = min(j + 1, chars.count)             // %=Nc
            default:
                flush()
                var j = i + 1
                while j < chars.count, chars[j] == "-" || chars[j].isNumber { j += 1 }
                let specifier = j < chars.count ? chars[j] : " "
                tokens.append(key == "articlelist" && specifier == "T"
                              ? .feedTitle : .wild)
                i = j + 1
            }
        }
        flush()
        return Signature(key: key, tokens: tokens)
    }

    static func signatures(configText: String?) -> [Signature] {
        titleFormats(configText: configText)
            .map { compile(key: $0.key, format: $0.value) }
            .sorted { $0.key < $1.key }   // deterministic tie order
    }

    // MARK: - Matching

    struct Match: Equatable {
        var key: String
        var score: Int
        var feedTitle: String?
    }

    /// Score one line against one signature: literals must appear in
    /// order (a wildcard between two literals lets anything sit there),
    /// and the score is how many literal characters agreed. The LAST
    /// literal may be cut short — newsboat truncates the title to the
    /// terminal width, and this user's formats are long — so a literal
    /// that isn't found whole still scores when a prefix of it (at least
    /// 3 chars) ends the line. nil = no agreement worth the name.
    static func match(line: String, signature: Signature) -> Match? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        var pos = text.startIndex
        var score = 0
        var captureFrom: String.Index?
        var feedTitle: String?
        var first = true
        for token in signature.tokens {
            switch token {
            case .wild:
                first = false
            case .feedTitle:
                captureFrom = pos
                first = false
            case .literal(let s):
                if let found = text.range(of: s, range: pos..<text.endIndex),
                   !first || found.lowerBound == text.startIndex {
                    if let from = captureFrom {
                        feedTitle = String(text[from..<found.lowerBound])
                            .trimmingCharacters(in: .whitespaces)
                        captureFrom = nil
                    }
                    score += s.count
                    pos = found.upperBound
                    first = false
                } else {
                    // Truncated tail?
                    if let cut = truncatedTail(of: s, ending: text, after: pos) {
                        if let from = captureFrom {
                            let end = text.index(text.endIndex, offsetBy: -cut)
                            feedTitle = String(text[from..<end])
                                .trimmingCharacters(in: .whitespaces)
                            captureFrom = nil
                        }
                        score += cut
                    }
                    return score >= minimumScore
                        ? Match(key: signature.key, score: score,
                                feedTitle: feedTitle)
                        : nil
                }
            }
        }
        if let from = captureFrom {
            feedTitle = String(text[from...])
                .trimmingCharacters(in: .whitespaces)
        }
        return score >= minimumScore
            ? Match(key: signature.key, score: score, feedTitle: feedTitle)
            : nil
    }

    /// The longest prefix of `literal` (≥ 3 chars) that is the suffix of
    /// `text` past `pos` — the shape a width-truncated title leaves.
    private static func truncatedTail(of literal: String, ending text: String,
                                      after pos: String.Index) -> Int? {
        let rest = text[pos...]
        var length = min(literal.count, rest.count)
        while length >= 3 {
            if rest.hasSuffix(literal.prefix(length)) { return length }
            length -= 1
        }
        return nil
    }

    /// The layer the screen shows. Every line is scored against every
    /// signature and the strongest agreement wins; a line two signatures
    /// tie on is ambiguous and ignored. nil = nothing on this screen
    /// looks like a newsboat title — a shell, a different program, or a
    /// format we can't recognise — and the caller must say so rather
    /// than guess.
    static func detect(screen: String, signatures: [Signature]) -> Layer? {
        var best: Match?
        for line in screen.components(separatedBy: .newlines) {
            var lineBest: Match?
            var tied = false
            for signature in signatures {
                guard let m = match(line: line, signature: signature) else { continue }
                if let current = lineBest {
                    if m.score > current.score {
                        lineBest = m
                        tied = false
                    } else if m.score == current.score {
                        tied = true
                    }
                } else {
                    lineBest = m
                }
            }
            guard let m = lineBest, !tied else { continue }
            if m.score > (best?.score ?? 0) { best = m }
        }
        return best.map(layer(for:))
    }

    static func layer(for match: Match) -> Layer {
        switch match.key {
        case "feedlist": return .feeds
        case "articlelist": return .articles(feedTitle: match.feedTitle)
        case "itemview": return .pager
        default: return .other(match.key)
        }
    }

    /// Whether `q` is a safe way OUT of this layer toward the lists. From
    /// the feed list q QUITS newsboat, and an unknown screen could be
    /// anything — neither may ever be climbed.
    static func climbsOut(of layer: Layer?) -> Bool {
        switch layer {
        case .pager?, .other?: return true
        case .feeds?, .articles?, nil: return false
        }
    }

    /// Log vocabulary for a layer — the dialog name only, never the feed
    /// title it may carry.
    static func logName(_ layer: Layer?) -> String {
        switch layer {
        case .feeds?: return "feed list"
        case .articles?: return "article list"
        case .pager?: return "pager"
        case .other(let key)?: return key
        case nil: return "unknown"
        }
    }
}
