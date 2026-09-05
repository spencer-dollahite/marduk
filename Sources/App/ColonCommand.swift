import Foundation

/// A parsed ":" command. Pure String logic — no side effects, unit-testable.
enum ColonCommand: Equatable {
    case help
    case commands
    case tutorial
    case tip
    case config(key: String, value: String)
    case voices
    case invertAppsList
    case news
    case stock(args: [String])
    case brief
    case segments
    case describe
    case ask(question: String)
    case pronunciation
    case typing
    case karabiner
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
    static let commandNames = ["help", "commands", "tutorial", "tip", "config",
                               "voices", "invertappslist", "news", "stock",
                               "brief", "segments", "describe", "ask",
                               "pronunciation", "typing", "karabiner",
                               "quit", "restart",
                               "update", "uninstall", "log", "feedback", "bug",
                               "security"]

    /// Commands that open a STAGED PICKER: the buffer stays in COMMAND
    /// mode while the user fuzzy-filters, and Return accepts the
    /// highlighted row instead of submitting the text. The daemon
    /// intercepts these before `parse`, so their enum cases exist for
    /// compiler exhaustiveness only.
    ///
    /// TABLE, not a code path: `voices` used to own eight hardcoded
    /// `hasPrefix("voices")` checks across three files, so a second picker
    /// would have meant a second copy of all of them.
    static let pickerCommands: Set<String> = ["voices", "invertappslist",
                                             "segments"]

    /// Pickers that ALSO answer under `:config` (the user asked for the
    /// whole inversion family to be `:config`-namespaced). These are NOT
    /// settings-table keys — a picker manages a list, not a key=value, and
    /// `invertapps` (the toggle) is a prefix of `invertappslist`, which the
    /// settings-prefix rule forbids. Instead `strippedPickerBuffer` rewrites
    /// `:config invertappslist …` down to the bare `:invertappslist …` form
    /// so ONE set of picker plumbing serves both. Bare still works too.
    static let configPickers: Set<String> = ["invertappslist", "segments"]

    /// Commands that EXPAND to "<name> " rather than executing — every
    /// picker, plus `config` and `stock` (which want more tokens next; a
    /// pause after ":stock" mid-way through "stock add …" must never
    /// execute-and-close under the typist).
    static let expandingCommands: Set<String> =
        pickerCommands.union(["config", "stock", "ask"])

    /// A picker buffer normalized to its BARE form (`"invertappslist …"`),
    /// recognizing both the bare spelling and the `:config`-namespaced one
    /// (`"config invertappslist …"` / `"set inv…"`, `config` itself
    /// prefix-expanded). Returns nil when the buffer targets no picker.
    ///
    /// Disambiguation at the `invertapps` (toggle) vs `invertappslist`
    /// (picker) boundary uses the same exact/unique-prefix rule as
    /// everywhere else, and a real settings key ALWAYS wins: `config
    /// invertapps` (and shorter) is the toggle; `config invertappsl…` is the
    /// picker. So the toggle is never shadowed by the picker.
    static func strippedPickerBuffer(_ buffer: String) -> String? {
        let lowered = buffer.lowercased()
        let tokens = lowered.split(separator: " ").map(String.init)
        guard let first = tokens.first else { return nil }
        // Already bare — hand it back unchanged (trailing space and filter
        // preserved), so callers can treat bare and namespaced alike.
        if pickerCommands.contains(first) { return lowered }
        // `:config <picker> …` / `:set <picker> …`, config prefix-expanded.
        let head = first == "set" ? "config" : expand(first, in: commandNames + ["set"])
        guard head == "config", tokens.count >= 2 else { return nil }
        let keyTok = tokens[1]
        // A settings key — exact, a unique prefix, OR still being typed
        // toward (an ambiguous prefix like "i", which could become
        // `identifiers` or `invertapps`) — is the TOGGLE path, never the
        // picker. Only a keyTok that NO setting could complete falls through
        // (`invertappsl…`, past where `invertapps` diverges), so the toggle
        // is never hijacked mid-type.
        if settings.contains(where: { $0.key.hasPrefix(keyTok) }) { return nil }
        guard let picker = expand(keyTok, in: Array(configPickers)) else { return nil }
        let remainder = tokens.dropFirst(2).joined(separator: " ")
        let trailing = lowered.hasSuffix(" ") ? " " : ""
        return remainder.isEmpty ? "\(picker) " : "\(picker) \(remainder)\(trailing)"
    }

    /// Does this buffer keep COMMAND mode open on Return? Pickers accept a
    /// row rather than submitting, and "/" is the fuzzy search. The event
    /// tap asks this instead of testing command names itself.
    static func staysOpenOnReturn(_ buffer: String) -> Bool {
        if buffer.hasPrefix("/") { return true }
        return strippedPickerBuffer(buffer) != nil
    }

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
        case "invertappslist":
            return .invertAppsList
        case "news":
            return .news
        case "stock":
            return .stock(args: Array(tokens.dropFirst()))
        case "brief":
            return .brief
        case "segments":
            // Picker — the daemon intercepts the buffer before parse; this
            // is the bare fallback (and compiler exhaustiveness).
            return .segments
        case "describe":
            return .describe
        case "ask":
            // A question is CONTENT: the whole tail, the user's own
            // capitalization (the text-setting rule)
            let original = raw.split(separator: " ").map(String.init)
            return .ask(question: original.dropFirst().joined(separator: " "))
        case "pronunciation":
            return .pronunciation
        case "typing":
            return .typing
        case "karabiner":
            return .karabiner
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
            guard tokens.count >= 3 else { return .unknown(raw) }
            // Expand key and (for enum kinds) value the same way, so
            // ":conf ra 230" runs as ":config rate 230". Ambiguous or
            // unknown prefixes pass through raw — the executor speaks
            // the error.
            let key = expand(tokens[1], in: settings.map(\.key)) ?? tokens[1]
            // A text setting swallows the whole tail, spaces included, and
            // keeps the user's own capitalization — `tokens` is lowercased
            // for grammar matching, but a note title is CONTENT.
            if kind(for: key)?.isText == true {
                let original = raw.split(separator: " ").map(String.init)
                return .config(key: key,
                               value: original.dropFirst(2)
                                   .joined(separator: " "))
            }
            guard tokens.count == 3 else { return .unknown(raw) }
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

        // A `:config`-namespaced picker collapses straight into the bare
        // picker stage (`config invertappslist` → `invertappslist `), so the
        // rest of the picker plumbing sees only the bare form. `nil` /
        // identity means "not a namespaced picker" — fall through.
        if let bare = strippedPickerBuffer(lowered), bare != lowered {
            return .expand(bare)
        }

        switch tokens.count {
        case 1:
            // "set" shadows the "se" prefix here too — a pause after "se"
            // mid-way through "set rate…" must stay ambiguous, not open
            // the security email
            guard let name = expand(tokens[0], in: commandNames + ["set"]),
                  name != "set" else { return .none }
            // Staged commands expand instead of executing: config wants a
            // key, voices opens the picker (selection accepts via Return)
            if expandingCommands.contains(name) { return .expand("\(name) ") }
            return .execute(name)

        case 2 where tokens[0] == "log":
            guard expand(tokens[1], in: ["copy"]) == "copy" else { return .none }
            return .execute("log copy")

        case _ where tokens[0] == "ask":
            // A question never auto-resolves — nothing can know it is
            // finished. Return sends it.
            return .none

        case 2 where tokens[0] == "stock":
            // Subcommand expands and waits for its symbol; symbols and
            // prices never auto-resolve (Enter ends them)
            guard let sub = expand(tokens[1], in: StockColonCommand.subcommands)
            else { return .none }
            return .expand("stock \(sub) ")

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
        /// Free text, spaces and all — a note title, a city, a feed name.
        /// The ONLY kind whose value may span more than one token, so
        /// `parse` takes the whole tail and Return is always required
        /// (auto-accept can never know the user has finished typing a
        /// phrase). `hint` is spoken in the palette's value stage.
        case text(hint: String)

        /// Free text is the only kind `parse` treats specially (it takes
        /// the whole tail), so the question gets a name instead of a
        /// pattern match repeated at three call sites.
        var isText: Bool {
            if case .text = self { return true }
            return false
        }
    }

    static let settings: [(key: String, kind: SettingKind)] = [
        ("rate", .number(min: 50, max: 360, unit: "words per minute")),
        ("pitch", .number(min: 50, max: 200, unit: "percent")),
        ("level", .choice(["none", "some", "most", "all"])),
        ("hashes", .toggle),
        ("identifiers", .toggle),
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
        ("dialogs", .choice(["all", "system", "off"])),
        // Shares the "dialog" stem with "dialogs" but neither is a prefix
        // of the other (7th char s vs f) — the guard test holds
        ("dialogfocus", .choice(["ask", "always", "off"])),
        ("hints", .toggle),   // progressive onboarding hints + questions
        ("follow", .toggle),
        // Two INDEPENDENT inversion switches, deliberately decoupled:
        // `invertapps` (on/off) drives ONLY the coded/listed apps (Pages,
        // Packet Tracer, plus the `:config invertappslist` picker's list)
        // via the Invert Colors hotkey; `smartinvert` drives ONLY
        // brightness sampling of UNLISTED apps. Neither implies the other.
        // The LIST is edited through the `invertappslist` picker (a command,
        // reachable as `:config invertappslist`), NOT a settings key —
        // `invertapps` is a prefix of `invertappslist`, which the
        // settings-prefix rule forbids for keys. Preview's dark PDFs stay
        // their own `preferdarkinpreview` switch — a menu-item press, not
        // display inversion.
        ("invertapps", .toggle),
        ("preferdarkinpreview", .choice(["auto", "on", "off"])),
        ("smartinvert", .toggle),
        ("dock", .toggle),
        // Extension switches: off reverts the key to its pre-extension
        // meaning (n → plain buzz, capital S → hover toggle). "stocks"
        // the SETTING vs "stock" the COMMAND live in different
        // namespaces — settings only ever parse under `config`.
        ("news", .toggle),
        ("stocks", .toggle),
        ("brief", .toggle),
        ("describe", .toggle),
        // IMAGE DESCRIPTION engine. Not "describer"/"describeengine":
        // "describe" (the switch above) would be their prefix.
        ("imagemodel", .choice(["auto", "apple", "ollama", "labels"])),
        // How much a description says (prompt length, token cap, label
        // and text budgets). "detail" shares "d" with describe/dialogs/
        // dock; none is a prefix of another.
        ("detail", .choice(["brief", "normal", "full"])),
        // The user's own words instead of Marduk's description prompt
        ("prompt", .text(hint: "your own prompt for describing pictures, or off")),
        // DAILY BRIEF setup. Every one of these is reachable from `:config`
        // on purpose — the brief is the one feature whose usefulness
        // depends entirely on setup, and a blind user must never be sent
        // to a JSON file to finish it. `place` geocodes; `note` searches
        // Notes by title; `horoscope` names a feed already in newsboat.
        // The segment LIST is the `:segments` picker, not a key here (a
        // picker manages a list, and "brief" is a prefix of any
        // "briefsegments" spelling, which the settings-prefix rule
        // forbids).
        ("note", .text(hint: "the title of a note in Notes")),
        ("place", .text(hint: "your city, for the weather")),
        ("horoscope", .text(hint: "part of a horoscope feed's name, or off")),
        ("units", .choice(["imperial", "metric"])),
        ("headlines", .number(min: 0, max: 20, unit: "headlines")),
    ]

    /// Spoken forms for keys that don't read aloud well. Anything absent
    /// speaks as its own key.
    static let spokenSettingNames: [String: String] = [
        "escapehold": "escape hold",
        "commandecho": "command echo",
        "autoupdate": "auto update",
        "checkhours": "check hours",
        "speedkeys": "speed keys",
        "togglesound": "toggle sound",
        "readmotions": "read motions",
        "dialogfocus": "dialog focus",
        "preferdarkinpreview": "prefer dark in preview",
        "smartinvert": "smart invert",
        "invertapps": "invert apps",
        "imagemodel": "image model",
    ]

    /// Every setting, spoken — GENERATED from the table, never written out
    /// by hand. The hand-maintained copy of this sentence drifted to 25 of
    /// 28 settings, so a user who mistyped a key was told that `position`,
    /// `dialogfocus`, and `hints` did not exist.
    static func spokenSettingList() -> String {
        settings.map { spokenSettingNames[$0.key] ?? $0.key }
            .joined(separator: ", ")
    }

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
        "invertappslist": "choose which apps invert the display",
        "news": "open the newsboat news reader",
        "stock": "manage the stock watchlist",
        "brief": "speak the daily brief now",
        "segments": "choose what the daily brief includes",
        "describe": "describe the image under the pointer",
        "ask": "ask about the last described image",
        "pronunciation": "open the system pronunciation editor",
        "typing": "open the system typing feedback settings",
        "karabiner": "apply your own Karabiner rules",
        "quit": "stop Marduk",
        "restart": "restart the daemon",
        "update": "install updates now",
        "uninstall": "remove the launch agent",
        "log": "open the log file",
        "feedback": "open GitHub issues",
        "bug": "report a bug on GitHub",
        "security": "report a security issue privately",
    ]

    /// One staged picker's rows, fuzzy-filtered by the typed remainder.
    /// Display names contain spaces, so the whole remainder is the query.
    private static func pickerRows(
        command: String, tokens: [String],
        source: [(name: String, identifier: String)]
    ) -> [Candidate] {
        let rows = source.map {
            Candidate(display: $0.name, completion: "\(command) \($0.identifier)")
        }
        // Tab/click fills the full identifier into the buffer — keep showing
        // that row (an identifier never fuzzy-matches the display names, and
        // an empty list would break Return)
        let remainder = tokens.dropFirst().joined(separator: " ")
        if let exact = source.first(where: { $0.identifier.lowercased() == remainder }) {
            return [Candidate(display: exact.name,
                              completion: "\(command) \(exact.identifier)")]
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

    private static func commandDisplay(_ name: String) -> String {
        guard let description = commandDescriptions[name] else { return name }
        return "\(name) — \(description)"
    }

    /// Staged commands complete with a trailing space (the buffer stays
    /// open for the next stage) instead of executing outright.
    private static func commandCompletion(_ name: String) -> String {
        ColonCommand.expandingCommands.contains(name) ? "\(name) " : name
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
                           voices: [(name: String, identifier: String)] = [],
                           apps: [(name: String, identifier: String)] = [],
                           segments: [(name: String, identifier: String)] = [])
        -> [Candidate] {
        var lowered = buffer.lowercased()

        // A `:config`-namespaced picker reuses the bare-picker completion
        // path — rewrite it down to the bare form first (identity for a
        // buffer that is already bare; only `config invertappslist …`
        // changes). Never touches "/" search or plain settings buffers.
        if !lowered.hasPrefix("/"), let bare = ColonCommand.strippedPickerBuffer(lowered) {
            lowered = bare
        }

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

        // Staged picker (":voices", ":invertapps") — the whole source list,
        // fuzzy-filtered by whatever is typed after the command name.
        // Return/Tab/click accept a row; the completion carries the
        // identifier the daemon acts on.
        if ColonCommand.pickerCommands.contains(tokens[0]) {
            let source: [(name: String, identifier: String)]
            switch tokens[0] {
            case "voices": source = voices
            case "segments": source = segments
            default: source = apps
            }
            return pickerRows(command: tokens[0], tokens: tokens, source: source)
        }

        // "log" has one optional argument
        if tokens[0] == "log" {
            let partial = tokens.count == 2 && !trailingSpace ? tokens[1] : ""
            guard tokens.count <= 2, "copy".hasPrefix(partial) else { return [] }
            return [Candidate(display: "copy — copy recent log lines to the clipboard",
                              completion: "log copy")]
        }

        // "ask" stage: a spoken prompt for the question; stays up until Return
        if tokens[0] == "ask" {
            return [Candidate(display: "your question about the last described picture"
                                  + " — Return sends it",
                              completion: nil)]
        }

        // "stock" stages: subcommand rows, then free-typed symbol/price
        if tokens[0] == "stock" {
            guard tokens.count <= 2 else { return [] }
            let partial = tokens.count == 2 && !trailingSpace ? tokens[1] : ""
            let rows: [(String, String)] = [
                ("add", "add a ticker — stock add A A P L"),
                ("remove", "remove a ticker"),
                ("buy", "buy alert — stock buy A A P L 180, or off"),
                ("sell", "sell alert — stock sell A A P L 220, or off"),
            ]
            return rows.filter { $0.0.hasPrefix(partial) }.map {
                Candidate(display: "\($0.0) — \($0.1)",
                          completion: "stock \($0.0) ")
            }
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
        // Free text spans any number of tokens, so it never has a
        // "partial" to filter on — the row is a spoken prompt for what to
        // type, and it stays up until Return.
        if case .text(let hint)? = ColonCommand.kind(for: key), tokens.count >= 2 {
            let current = values[key].map { " — now \($0)" } ?? ""
            return [Candidate(display: "\(hint)\(current)", completion: nil)]
        }
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
        case .text:
            return []   // handled above — free text has no candidate list
        }
    }
}
