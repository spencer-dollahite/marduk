import Foundation

/// A parsed ":" command. Pure String logic — no side effects, unit-testable.
enum ColonCommand: Equatable {
    case help
    case commands
    case tutorial
    case tip
    case config(key: String, value: String)
    case unknown(String)

    static let commandNames = ["help", "commands", "tutorial", "tip", "config"]

    static func parse(_ raw: String) -> ColonCommand {
        let tokens = raw.lowercased().split(separator: " ").map(String.init)
        guard let first = tokens.first else { return .unknown("") }

        // Explicit aliases win, then vim-style unique-prefix expansion
        let name: String?
        switch first {
        case "h": name = "help"
        case "c": name = "commands"
        case "set": name = "config"
        default: name = expand(first, in: commandNames)
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

    /// Candidates for the current buffer. `values` maps setting key → spoken
    /// current value, so the palette shows "rate — 200" style rows.
    static func candidates(for buffer: String, values: [String: String]) -> [Candidate] {
        let lowered = buffer.lowercased()
        let tokens = lowered.split(separator: " ").map(String.init)
        let trailingSpace = lowered.hasSuffix(" ")

        // Stage 1: choosing a command
        if tokens.isEmpty {
            return ColonCommand.commandNames.map { Candidate(display: $0, completion: $0) }
        }
        if tokens.count == 1 && !trailingSpace {
            let matches = ColonCommand.commandNames.filter { $0.hasPrefix(tokens[0]) }
            return matches.map {
                Candidate(display: $0, completion: $0 == "config" ? "config " : $0)
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
