import Foundation

/// A parsed ":" command. Pure String logic — no side effects, unit-testable.
enum ColonCommand: Equatable {
    case help
    case commands
    case tutorial
    case tip
    case config(key: String, value: String)
    case voices
    case quit
    case restart
    case update
    case uninstall
    case log
    case logCopy
    case feedback
    case bug
    case security
    case unknown(String)

    // No name may be a prefix of another — auto-accept relies on it
    // (the tap's Return handler also assumes "voices" owns that prefix)
    static let commandNames = ["help", "commands", "tutorial", "tip", "config",
                               "voices", "quit", "restart", "update",
                               "uninstall", "log", "feedback", "bug", "security"]

    static func parse(_ raw: String) -> ColonCommand {
        let tokens = raw.lowercased().split(separator: " ").map(String.init)
        guard let first = tokens.first else { return .unknown("") }

        // Explicit aliases win, then vim-style unique-prefix expansion.
        // "set" (the config alias) isn't a commandName but must shadow the
        // "se" prefix — ":se ra 230" is vim muscle memory for :set and can
        // never be allowed to expand to "security".
        let name: String?
        switch first {
        case "h": name = "help"
        case "c": name = "commands"
        case "set": name = "config"
        default:
            let expanded = expand(first, in: commandNames + ["set"])
            name = expanded == "set" ? "config" : expanded
        }

        switch name {
        case "help":
            return .help
        case "commands":
            return .commands
        case "tutorial":
            return .tutorial
        case "tip":
            return .tip
        case "voices":
            // Extra tokens are picker filter text — the daemon accepts the
            // palette selection before ever parsing, so bare .voices is
            // only reached as a fallback.
            return .voices
        case "quit":
            return .quit
        case "restart":
            return .restart
        case "update":
            return .update
        case "uninstall":
            return .uninstall
        case "log":
            if tokens.count == 2, expand(tokens[1], in: ["copy"]) == "copy" {
                return .logCopy
            }
            return tokens.count == 1 ? .log : .unknown(raw)
        case "feedback":
            return .feedback
        case "bug":
            return .bug
        case "security":
            return .security
        case "config":
            guard tokens.count == 3 else { return .unknown(raw) }
            // Expand key and (for enum kinds) value the same way, so
            // ":conf ra 230" runs as ":config rate 230". Ambiguous or
            // unknown prefixes pass through raw — the executor speaks
            // the error.
            let key = expand(tokens[1], in: settings.map(\.key)) ?? tokens[1]
            let value: String
            switch kind(for: key) {
            case .toggle:
                value = expand(tokens[2], in: ["on", "off"]) ?? tokens[2]
            case .choice(let options):
                value = expand(tokens[2], in: options) ?? tokens[2]
            default:
                value = tokens[2]
            }
            return .config(key: key, value: value)
        default:
            return .unknown(first)
        }
    }

    /// Unique-prefix expansion: exact match wins; else the single name with
    /// this prefix; ambiguous or no match → nil.
    static func expand(_ prefix: String, in names: [String]) -> String? {
        guard !prefix.isEmpty else { return nil }
        if names.contains(prefix) { return prefix }
        let matches = names.filter { $0.hasPrefix(prefix) }
        return matches.count == 1 ? matches.first : nil
    }

    // MARK: - Auto-accept (dmenu semantics)

    /// What to do the moment a keystroke makes the buffer unambiguous:
    /// argless commands and final enum values execute immediately; "config"
    /// and its keys expand and advance to the next stage. Number values
    /// return .none — only Enter can end those. Safe because no grammar
    /// word is a prefix of another.
    enum AutoResolution: Equatable {
        case none
        case expand(String)    // replace the buffer, keep typing
        case execute(String)   // run it now, leave COMMAND mode
    }

    static func autoResolve(_ buffer: String) -> AutoResolution {
        let lowered = buffer.lowercased()
        // Fuzzy-search buffers ("/query") only resolve by explicit pick
        guard !lowered.hasPrefix("/") else { return .none }
        // A trailing space means "next token not started" — nothing to resolve
        guard !lowered.isEmpty, !lowered.hasSuffix(" ") else { return .none }
        let tokens = lowered.split(separator: " ").map(String.init)

        switch tokens.count {
        case 1:
            // "set" shadows the "se" prefix here too — a pause after "se"
            // mid-way through "set rate…" must stay ambiguous, not open
            // the security email
            guard let name = expand(tokens[0], in: commandNames + ["set"]),
                  name != "set" else { return .none }
            // Staged commands expand instead of executing: config wants a
            // key, voices opens the picker (selection accepts via Return)
            if name == "config" || name == "voices" { return .expand("\(name) ") }
            return .execute(name)

        case 2 where tokens[0] == "log":
            guard expand(tokens[1], in: ["copy"]) == "copy" else { return .none }
            return .execute("log copy")

        case 2 where tokens[0] == "config" || tokens[0] == "set":
            guard let key = expand(tokens[1], in: settings.map(\.key)) else { return .none }
            return .expand("\(tokens[0]) \(key) ")

        case 3 where tokens[0] == "config" || tokens[0] == "set":
            guard let key = expand(tokens[1], in: settings.map(\.key)) else { return .none }
            switch kind(for: key) {
            case .toggle:
                if let value = expand(tokens[2], in: ["on", "off"]) {
                    return .execute("\(tokens[0]) \(key) \(value)")
                }
            case .choice(let options):
                if let value = expand(tokens[2], in: options) {
                    return .execute("\(tokens[0]) \(key) \(value)")
                }
            default:
                break
            }
            return .none

        default:
            return .none
        }
    }

    // MARK: - Settings table (shared by the completer and the daemon's validator)

    enum SettingKind: Equatable {
        case number(min: Int, max: Int, unit: String)
        case toggle
        case choice([String])
    }

    static let settings: [(key: String, kind: SettingKind)] = [
        ("rate", .number(min: 50, max: 360, unit: "words per minute")),
        ("level", .choice(["none", "some", "most", "all"])),
        ("hashes", .toggle),
        ("rescue", .toggle),
        ("burst", .number(min: 50, max: 2000, unit: "milliseconds")),
        ("escapehold", .number(min: 100, max: 2000, unit: "milliseconds")),
        ("echo", .toggle),
        ("commandecho", .toggle),
        ("palette", .toggle),
        ("position", .choice(["center", "pointer"])),
        ("autoupdate", .toggle),
        ("checkhours", .number(min: 0, max: 168, unit: "hours")),
        ("border", .toggle),
        ("pointer", .toggle),
        ("thickness", .number(min: 1, max: 40, unit: "points")),
        // NOT "ratekeys" — "rate" would be its prefix, breaking expansion
        ("speedkeys", .toggle),
        ("togglesound", .choice(["speech", "earcon"])),
        ("readmotions", .toggle),
    ]

    static func kind(for key: String) -> SettingKind? {
        settings.first { $0.key == key }?.kind
    }
}

/// Autocomplete candidates for the command palette. Pure logic.
enum CommandCompleter {

    struct Candidate: Equatable {
        /// Shown in the palette and spoken when arrow-selected.
        let display: String
        /// Buffer replacement on Tab. Nil = informational row (range hints).
        let completion: String?
    }

    private static let commandDescriptions: [String: String] = [
        "help": "speak the basics",
        "commands": "the full key reference",
        "tutorial": "interactive guided tour",
        "tip": "a random feature tip",
        "config": "change a setting",
        "voices": "choose the reading voice",
        "quit": "stop Marduk",
        "restart": "restart the daemon",
        "update": "install updates now",
        "uninstall": "remove the launch agent",
        "log": "open the log file",
        "feedback": "open GitHub issues",
        "bug": "report a bug on GitHub",
        "security": "report a security issue privately",
    ]

    private static func commandDisplay(_ name: String) -> String {
        guard let description = commandDescriptions[name] else { return name }
        return "\(name) — \(description)"
    }

    /// Staged commands complete with a trailing space (the buffer stays
    /// open for the next stage) instead of executing outright.
    private static func commandCompletion(_ name: String) -> String {
        name == "config" || name == "voices" ? "\(name) " : name
    }

    /// Everything "/" search can land on: all commands + all config keys.
    private static func catalogEntries(values: [String: String]) -> [Candidate] {
        var entries = ColonCommand.commandNames.map {
            Candidate(display: commandDisplay($0), completion: commandCompletion($0))
        }
        entries += ColonCommand.settings.map { setting in
            let current = values[setting.key].map { " — \($0)" } ?? ""
            return Candidate(display: "config \(setting.key)\(current)",
                             completion: "config \(setting.key) ")
        }
        return entries
    }

    /// Greedy subsequence match; lower score = tighter match (gaps and a
    /// late start cost points). Nil = no match.
    static func fuzzyScore(query: String, target: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        var score = 0
        var lastIndex = -1
        var qi = query.startIndex
        for (i, ch) in target.enumerated() {
            guard qi < query.endIndex else { break }
            if ch == query[qi] {
                score += lastIndex >= 0 ? (i - lastIndex - 1) : i
                lastIndex = i
                qi = query.index(after: qi)
            }
        }
        return qi == query.endIndex ? score : nil
    }

    /// Candidates for the current buffer. `values` maps setting key → spoken
    /// current value, so the palette shows "rate — 200" style rows. `voices`
    /// feeds the ":voices" picker stage (dynamic — the daemon supplies the
    /// installed list; tests pass a fixture).
    static func candidates(for buffer: String, values: [String: String],
                           voices: [(name: String, identifier: String)] = []) -> [Candidate] {
        let lowered = buffer.lowercased()

        // "/query" — fuzzy search across the whole catalog (commands +
        // every config setting), ranked by match tightness
        if lowered.hasPrefix("/") {
            let query = String(lowered.dropFirst()).replacingOccurrences(of: " ", with: "")
            let catalog = catalogEntries(values: values)
            guard !query.isEmpty else { return catalog }
            return catalog
                .compactMap { entry -> (Candidate, Int)? in
                    let key = (entry.completion ?? entry.display).lowercased()
                    guard let score = fuzzyScore(query: query, target: key) else { return nil }
                    return (entry, score)
                }
                .sorted { $0.1 < $1.1 }
                .map(\.0)
        }

        let tokens = lowered.split(separator: " ").map(String.init)
        let trailingSpace = lowered.hasSuffix(" ")

        // Stage 1: choosing a command
        if tokens.isEmpty {
            return ColonCommand.commandNames.map {
                Candidate(display: commandDisplay($0), completion: commandCompletion($0))
            }
        }
        if tokens.count == 1 && !trailingSpace {
            let matches = ColonCommand.commandNames.filter { $0.hasPrefix(tokens[0]) }
            return matches.map {
                Candidate(display: commandDisplay($0), completion: commandCompletion($0))
            }
        }

        // ":voices" picker stage — every installed voice, fuzzy-filtered by
        // whatever is typed after the command (names contain spaces, so the
        // whole remainder is the query). Return/Tab/click accept a row; the
        // completion carries the identifier.
        if tokens[0] == "voices" {
            let rows = voices.map {
                Candidate(display: $0.name, completion: "voices \($0.identifier)")
            }
            // Tab/click fills the full identifier into the buffer — keep
            // showing that voice's row (an identifier never fuzzy-matches
            // the display names, and an empty list would break Return)
            let remainder = tokens.dropFirst().joined(separator: " ")
            if let exact = voices.first(where: { $0.identifier.lowercased() == remainder }) {
                return [Candidate(display: exact.name, completion: "voices \(exact.identifier)")]
            }
            let query = tokens.dropFirst().joined().lowercased()
            guard !query.isEmpty else { return rows }
            return rows
                .compactMap { row -> (Candidate, Int)? in
                    guard let score = fuzzyScore(query: query,
                                                 target: row.display.lowercased()) else { return nil }
                    return (row, score)
                }
                .sorted { $0.1 < $1.1 }
                .map(\.0)
        }

        // "log" has one optional argument
        if tokens[0] == "log" {
            let partial = tokens.count == 2 && !trailingSpace ? tokens[1] : ""
            guard tokens.count <= 2, "copy".hasPrefix(partial) else { return [] }
            return [Candidate(display: "copy — copy recent log lines to the clipboard",
                              completion: "log copy")]
        }

        // Stages 2/3 only exist under config (or its set alias)
        guard tokens[0] == "config" || tokens[0] == "set" else { return [] }
        let prefix = tokens[0]

        // Stage 2: choosing a setting key
        let keyPartial: String? = {
            if tokens.count == 1 && trailingSpace { return "" }
            if tokens.count == 2 && !trailingSpace { return tokens[1] }
            return nil
        }()
        if let partial = keyPartial {
            return ColonCommand.settings
                .filter { $0.key.hasPrefix(partial) }
                .map { setting in
                    let current = values[setting.key].map { " — \($0)" } ?? ""
                    return Candidate(display: setting.key + current,
                                     completion: "\(prefix) \(setting.key) ")
                }
        }

        // Stage 3: choosing a value
        let key = tokens[1]
        let valuePartial: String? = {
            if tokens.count == 2 && trailingSpace { return "" }
            if tokens.count == 3 && !trailingSpace { return tokens[2] }
            return nil
        }()
        guard let partial = valuePartial, let kind = ColonCommand.kind(for: key) else {
            return []
        }
        switch kind {
        case .toggle:
            return ["on", "off"]
                .filter { $0.hasPrefix(partial) }
                .map { Candidate(display: $0, completion: "\(prefix) \(key) \($0)") }
        case .choice(let options):
            return options
                .filter { $0.hasPrefix(partial) }
                .map { Candidate(display: $0, completion: "\(prefix) \(key) \($0)") }
        case .number(let min, let max, let unit):
            return [Candidate(display: "\(min) to \(max) \(unit)", completion: nil)]
        }
    }
}
