import Foundation

/// LLM triage over the unread headlines (`t` in NEWS mode): a local
/// Ollama model picks the 3 most critical or novel stories and clusters
/// near-duplicates, so the user hears what matters instead of wading
/// through eight copies of the same advisory. Everything here is PURE —
/// prompt building, response parsing, spoken-summary composition — the
/// network lives in NewsReader. Headlines are user content: they go to
/// LOCALHOST only and are never logged.
enum NewsTriage {

    struct Item: Equatable {
        var id: Int64        // rss_item id — the jump target
        var feedTitle: String
        var title: String
    }

    struct Pick: Equatable {
        var item: Item
        var why: String      // the model's few-word reason
    }

    struct Result: Equatable {
        var top: [Pick]           // up to 3, model order
        var duplicatesCollapsed: Int
    }

    /// Numbered headline list + strict-JSON instructions. Temperature 0
    /// and `format: json` ride in the request; small local models still
    /// wander, so the parser below trusts nothing.
    static func prompt(items: [Item]) -> String {
        var lines: [String] = []
        lines.append("""
            You triage cybersecurity headlines for a blind user who \
            listens to them read aloud. Below is a numbered list of \
            headlines with their sources. Reply with STRICT JSON only, \
            exactly this shape:
            {"top":[{"n":1,"why":"short reason"},{"n":2,"why":"…"},\
            {"n":3,"why":"…"}],"dupes":[[2,5,9],[3,7]]}
            "top" is the 3 most critical or genuinely novel stories \
            (favor active exploitation, severity, breadth of impact, \
            true novelty). "why" is at most 8 words. "dupes" groups \
            numbers that cover the SAME story; leave it empty if all \
            differ. Use only numbers from the list.

            Headlines:
            """)
        for (index, item) in items.enumerated() {
            lines.append("\(index + 1). [\(item.feedTitle)] \(item.title)")
        }
        return lines.joined(separator: "\n")
    }

    /// Parse the model's JSON against the item list. Defensive at every
    /// step: bad numbers drop, duplicate picks collapse, anything
    /// unparseable returns nil (the caller speaks an honest failure).
    static func parse(response: String, items: [Item]) -> Result? {
        guard let json = extractJSON(response),
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            return nil
        }
        var picks: [Pick] = []
        var seen = Set<Int>()
        for entry in root["top"] as? [[String: Any]] ?? [] {
            guard let n = (entry["n"] as? NSNumber)?.intValue,
                  n >= 1, n <= items.count, !seen.contains(n) else { continue }
            seen.insert(n)
            let why = (entry["why"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            picks.append(Pick(item: items[n - 1], why: why))
            if picks.count == 3 { break }
        }
        guard !picks.isEmpty else { return nil }
        var collapsed = 0
        for group in root["dupes"] as? [[Any]] ?? [] {
            let valid = Set(group.compactMap { ($0 as? NSNumber)?.intValue }
                .filter { $0 >= 1 && $0 <= items.count })
            if valid.count > 1 { collapsed += valid.count - 1 }
        }
        return Result(top: picks, duplicatesCollapsed: collapsed)
    }

    /// Models wrap JSON in prose or code fences; take the outermost braces.
    static func extractJSON(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"), start < end else { return nil }
        return String(text[start...end])
    }

    /// The spoken summary: ordinal, title, source, the model's reason —
    /// ending on the 1/2/3 question the daemon arms.
    static func spoken(_ result: Result) -> String {
        let ordinals = ["One", "Two", "Three"]
        var parts: [String] = ["Top \(result.top.count)."]
        for (index, pick) in result.top.enumerated() {
            var line = "\(ordinals[index]): \(pick.item.title), from "
                + pick.item.feedTitle
            if !pick.why.isEmpty { line += ". \(pick.why)" }
            parts.append(line + ".")
        }
        if result.duplicatesCollapsed > 0 {
            parts.append("\(result.duplicatesCollapsed) duplicates collapsed.")
        }
        let keys = result.top.count == 1 ? "1"
            : (1...result.top.count).map(String.init).joined(separator: ", ")
        parts.append("Press \(keys) to read.")
        return parts.joined(separator: " ")
    }

    /// Choose a model from Ollama's tag list: the configured name wins;
    /// unconfigured, gemma3 beats the rest of the gemm family — on a
    /// 16 GB machine the 3.3 GB gemma3:4b loads and answers in seconds
    /// while gemma4:e4b (9.6 GB) mostly loads (user ruling 2026-08-04:
    /// fastest wins for headline triage; pin news.ollamaModel to trade
    /// up). Then any gemm-family tag, then the first model at all.
    static func pickModel(configured: String?, available: [String]) -> String? {
        if let configured, !configured.isEmpty {
            if available.contains(configured) { return configured }
            // A configured prefix ("gemma4") still finds its full tag
            if let match = available.first(where: { $0.hasPrefix(configured) }) {
                return match
            }
            return configured  // trust the user; Ollama will say if it's wrong
        }
        return available.first { $0.lowercased().hasPrefix("gemma3") }
            ?? available.first { $0.lowercased().contains("gemm") }
            ?? available.first
    }
}
