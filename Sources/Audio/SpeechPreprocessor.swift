import Foundation

/// Prepares text for AVSpeechSynthesizer: strips characters that make the
/// synthesizer stop early or skip content (control chars, invisible Unicode),
/// abbreviates hex digests ("md5 ending in 2 7 e"), speaks code symbols as
/// words per the configured verbosity, and normalizes whitespace. Pure
/// String logic — no AVFoundation.
enum SpeechPreprocessor {

    enum Verbosity: String {
        case none, some, most, all
    }

    /// Immutable, precompiled at construction — speak() does zero table building.
    struct Settings {
        let verbosity: Verbosity
        /// Digraphs + multi-char overrides, longest key first.
        let multi: [(key: String, name: String)]
        /// Effective single-char map for this level. Empty name = silenced.
        let single: [Character: String]
        /// Names for collapsing symbol runs (≥3). Falls back to the full
        /// table so `---` says "3 dash" at most even though a lone dash is
        /// left to natural pausing. Empty at .none.
        let runNames: [Character: String]
        /// Abbreviate hex digests ("md5 ending in 2 7 e"). Independent of
        /// verbosity — it rewrites content, not symbols.
        let hashes: Bool
        /// Split camelCase / snake_case identifiers into natural words
        /// ("readDocumentFromCaret" → "read Document From Caret"). Content
        /// rewriting like hashes: own toggle, runs at every level.
        let identifiers: Bool

        static let `default` = Settings(verbosity: .most, overrides: [:])

        init(verbosity: Verbosity, overrides: [String: String], hashes: Bool = true,
             identifiers: Bool = true) {
            self.verbosity = verbosity
            self.hashes = hashes
            self.identifiers = identifiers

            var single: [Character: String] = [:]
            var multi: [(key: String, name: String)] = []

            switch verbosity {
            case .none:
                break
            case .some:
                for ch in SpeechPreprocessor.someSymbols {
                    single[ch] = SpeechPreprocessor.asciiNames[ch]
                }
            case .most:
                single = SpeechPreprocessor.asciiNames.filter {
                    !SpeechPreprocessor.prosePunctuation.contains($0.key)
                }
                single.merge(SpeechPreprocessor.unicodeExtras) { current, _ in current }
                multi = SpeechPreprocessor.digraphs
            case .all:
                single = SpeechPreprocessor.asciiNames
                single.merge(SpeechPreprocessor.unicodeExtras) { current, _ in current }
                multi = SpeechPreprocessor.digraphs
            }

            // Overrides merge last: rename an existing symbol, add a new one,
            // or silence one with an empty name. Inactive at .none.
            if verbosity != .none {
                for (key, name) in overrides {
                    if key.count == 1, let ch = key.first {
                        single[ch] = name
                    } else if !key.isEmpty {
                        if let idx = multi.firstIndex(where: { $0.key == key }) {
                            multi[idx].name = name
                        } else {
                            multi.append((key: key, name: name))
                        }
                    }
                }
                multi.sort { $0.key.count > $1.key.count }
            }

            var runNames: [Character: String] = [:]
            if verbosity != .none {
                runNames = SpeechPreprocessor.asciiNames
                runNames.merge(SpeechPreprocessor.unicodeExtras) { current, _ in current }
                // Level renames, user overrides, and silences win over the table
                runNames.merge(single) { _, levelName in levelName }
            }

            self.single = single
            self.multi = multi
            self.runNames = runNames
        }
    }

    /// Builds Settings from the config block; unknown levels fall back to most.
    static func settings(from block: MardukConfig.VerbalizerConfig?) -> Settings {
        let levelString = block?.level ?? "most"
        let verbosity: Verbosity
        if let parsed = Verbosity(rawValue: levelString.lowercased()) {
            verbosity = parsed
        } else {
            fputs("[verbalizer] unknown level '\(levelString)', using most\n", stderr)
            verbosity = .most
        }
        return Settings(verbosity: verbosity, overrides: block?.symbols ?? [:],
                        hashes: block?.hashes ?? true,
                        identifiers: block?.identifiers ?? true)
    }

    /// Full pipeline. Returns "" when nothing speakable remains.
    static func process(_ text: String, settings: Settings) -> String {
        // INPUT cap, before any pass: the pipeline is several O(n) walks
        // with grapheme segmentation, and the output is capped at 50k
        // anyway — processing more input is pure wasted main-thread time.
        // Field incident: R in Terminal handed over a 9.1 MILLION char
        // scrollback; seconds of blocked main thread starved the event
        // tap and froze keyboard input system-wide. utf16.count is the
        // cheap gate; the cut itself only walks the kept prefix.
        var text = text
        if text.utf16.count > maxInputLength {
            let originalUTF16 = text.utf16.count
            let cut = text.index(text.startIndex, offsetBy: maxInputLength,
                                 limitedBy: text.endIndex) ?? text.endIndex
            text = String(text[..<cut])
            fputs("[verbalizer] input capped (\(originalUTF16) chars)\n", stderr)
        }
        var result = sanitize(text)
        if settings.hashes {
            result = abbreviateHashes(result)
        }
        if settings.identifiers {
            result = splitIdentifiers(result)
        }
        result = normalizeWhitespace(verbalize(result, settings: settings))
        if result.count > maxSpokenLength {
            let capIndex = result.index(result.startIndex, offsetBy: maxSpokenLength)
            let head = result[..<capIndex]
            if let cut = head.lastIndex(where: { $0 == " " || $0 == "\n" }) {
                result = String(result[..<cut])
            } else {
                result = String(head)
            }
            fputs("[verbalizer] truncated pathological input (\(text.count) chars)\n", stderr)
        }
        return result
    }

    // MARK: - Stage 1: sanitize

    /// Removes everything that can truncate or break an utterance. Runs at
    /// every verbosity level, including .none.
    static func sanitize(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(scalars.count)
        var lastKept: Unicode.Scalar?

        func keep(_ s: Unicode.Scalar) {
            out.append(s)
            lastKept = s
        }

        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            defer { i += 1 }

            // Line endings → \n (CRLF collapses to the LF kept next iteration)
            if s == "\r" {
                if i + 1 < scalars.count && scalars[i + 1] == "\n" { continue }
                keep("\n")
                continue
            }
            if s.value == 0x85 || s.value == 0x2028 || s.value == 0x2029 {
                keep("\n")
                continue
            }
            if s == "\n" || s == "\t" {
                keep(s)
                continue
            }
            // ZWJ survives only inside an emoji sequence (👨‍👩‍👧 stays one glyph);
            // a stray text ZWJ is dropped like any other format char.
            if s.value == 0x200D {
                if let prev = lastKept, prev.properties.isEmojiPresentation,
                   i + 1 < scalars.count, scalars[i + 1].properties.isEmojiPresentation {
                    keep(s)
                }
                continue
            }
            // Variation selectors (other combining marks are kept)
            if (0xFE00...0xFE0F).contains(s.value) || (0xE0100...0xE01EF).contains(s.value) {
                continue
            }
            // Object-replacement and replacement characters
            if s.value == 0xFFFC || s.value == 0xFFFD {
                continue
            }
            switch s.properties.generalCategory {
            case .control, .format, .privateUse, .surrogate, .unassigned:
                continue
            case .spaceSeparator:
                keep(" ")
            default:
                keep(s)
            }
        }
        return String(out)
    }

    // MARK: - Stage 2: hash abbreviation

    /// Collapses hex digests to "<name> ending in x y z" instead of spelling
    /// out every character. A digest is a maximal alphanumeric run that is
    /// all-hex at one of the standard lengths — naming is by length
    /// convention (any 64-hex digest reads as "sha256"). Requires at least
    /// one digit AND one letter so 32-digit numeric IDs aren't mislabeled;
    /// a real digest missing one or the other is a ~1-in-3-million case.
    /// The tail is space-separated so TTS spells it ("a c e", not "ace").
    static func abbreviateHashes(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(chars.count)

        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }

        var i = 0
        while i < chars.count {
            guard isWordChar(chars[i]) else {
                out.append(chars[i])
                i += 1
                continue
            }
            var j = i + 1
            while j < chars.count && isWordChar(chars[j]) { j += 1 }
            let run = chars[i..<j]

            if let name = hashNames[run.count],
               run.allSatisfy({ $0.isASCII && $0.isHexDigit }),
               run.contains(where: { $0.isNumber }),
               run.contains(where: { $0.isLetter }) {
                let tail = run.suffix(3).map(String.init).joined(separator: " ")
                out += "\(name) ending in \(tail)"
            } else {
                out += String(run)
            }
            i = j
        }
        return out
    }

    // MARK: - Stage 2.5: identifier splitting

    /// Splits code identifiers into natural words: camel humps and internal
    /// underscores become spaces ("parseHTMLBody_v2" → "parse HTML Body v 2").
    /// A token only qualifies when it carries identifier evidence — an
    /// underscore with alphanumerics on both sides, a lower→upper hump, or a
    /// digit→upper hump in a token that also has lowercase — so ordinary
    /// words, ALLCAPS acronyms ("APT"), and digit-suffixed acronyms
    /// ("UTF16") pass through untouched, and hex runs were already collapsed
    /// by the hash stage. Leading/trailing/doubled underscores ("__init__")
    /// are left for the symbol stage. Runs after hashes, before verbalize;
    /// whitespace normalization later collapses any doubling.
    static func splitIdentifiers(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(chars.count + 16)

        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        func isAlnum(_ c: Character) -> Bool { c.isLetter || c.isNumber }

        var i = 0
        while i < chars.count {
            guard isWordChar(chars[i]) else {
                out.append(chars[i])
                i += 1
                continue
            }
            var j = i + 1
            while j < chars.count && isWordChar(chars[j]) { j += 1 }
            let token = Array(chars[i..<j])
            i = j

            var hasSnake = false
            var hasHump = false
            var hasLower = false
            for k in token.indices {
                let c = token[k]
                if c.isLowercase { hasLower = true }
                if k > 0 {
                    let p = token[k - 1]
                    if c == "_", k + 1 < token.count,
                       isAlnum(p), isAlnum(token[k + 1]) { hasSnake = true }
                    if c.isUppercase && p.isLowercase { hasHump = true }
                    if c.isUppercase && p.isNumber { hasHump = true }
                }
            }
            guard hasSnake || (hasHump && hasLower) else {
                out += String(token)
                continue
            }

            for k in token.indices {
                let c = token[k]
                if c == "_" {
                    let internalUnderscore = k > 0 && k + 1 < token.count
                        && isAlnum(token[k - 1]) && isAlnum(token[k + 1])
                    out.append(internalUnderscore ? " " : "_")
                    continue
                }
                if k > 0 {
                    let p = token[k - 1]
                    let boundary =
                        (c.isUppercase && (p.isLowercase || p.isNumber))
                        // Acronym → word: split before the last capital of a
                        // run when a lowercase follows ("XMLHttp" → XML Http)
                        || (c.isUppercase && p.isUppercase
                            && k + 1 < token.count && token[k + 1].isLowercase)
                        || (c.isNumber && p.isLetter)
                        || (c.isLetter && p.isNumber)
                    if boundary { out.append(" ") }
                }
                out.append(c)
            }
        }
        return out
    }

    // MARK: - Stage 3: verbalize

    /// Replaces symbols with spoken names and collapses/caps symbol runs.
    /// The run cap applies even with empty tables (verbosity .none).
    static func verbalize(_ text: String, settings: Settings) -> String {
        let chars = Array(text)
        let multi = settings.multi.map { (key: Array($0.key), name: $0.name) }
        var out = ""
        out.reserveCapacity(chars.count)

        var i = 0
        while i < chars.count {
            let c = chars[i]

            // Maximal same-character run, resolved before digraphs so "===="
            // can't be eaten as two "==".
            var j = i + 1
            while j < chars.count && chars[j] == c { j += 1 }
            let runLength = j - i

            if runLength >= 3 {
                if c == ".", runLength == 3, settings.single["."] == nil {
                    // A bare ellipsis is prose — keep the natural pause.
                    // (.all puts "." in single, so it says "3 dot" there.)
                    out += "..."
                } else if let name = settings.runNames[c] {
                    out += name.isEmpty ? " " : " \(runLength) \(name) "
                } else if isPunctuationOrSymbol(c) {
                    // Unnamed symbol runs are capped — pathological-run defense
                    out += String(repeating: String(c), count: 3)
                } else {
                    out += String(repeating: String(c), count: runLength)
                }
                i = j
                continue
            }

            if let match = multi.first(where: { entry in
                i + entry.key.count <= chars.count
                    && chars[i..<i + entry.key.count].elementsEqual(entry.key)
            }) {
                out += " \(match.name) "
                i += match.key.count
                continue
            }

            if let name = settings.single[c] {
                // "#" is three words in spoken English: "#66" is NUMBER
                // 66, "#topic" / "#tag2you" / "#!" are HASHTAGs, and a
                // standalone "#" is hash. The following run decides: all
                // digits → number, anything else attached → hashtag,
                // whitespace/end → hash. A user override of "#" wins in
                // every context, unchanged.
                if c == "#", name == "hash",
                   i + 1 < chars.count, !chars[i + 1].isWhitespace {
                    var sawLetter = false
                    var sawDigit = false
                    var j = i + 1
                    while j < chars.count, chars[j].isLetter || chars[j].isNumber {
                        if chars[j].isLetter { sawLetter = true } else { sawDigit = true }
                        j += 1
                    }
                    out += (sawDigit && !sawLetter) ? " number " : " hashtag "
                } else {
                    out += name.isEmpty ? " " : " \(name) "
                }
            } else {
                out.append(c)
            }
            i += 1
        }
        return out
    }

    // MARK: - Stage 4: whitespace

    /// Collapses space/tab runs to one space and blank-line runs to one
    /// newline (AVSpeech pauses on \n naturally — no injected periods),
    /// then trims the ends.
    static func normalizeWhitespace(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var pendingSpace = false
        var pendingNewline = false

        for c in text {
            if c == "\n" {
                pendingNewline = true
            } else if c == " " || c == "\t" {
                pendingSpace = true
            } else {
                if !out.isEmpty {
                    if pendingNewline {
                        out.append("\n")
                    } else if pendingSpace {
                        out.append(" ")
                    }
                }
                pendingNewline = false
                pendingSpace = false
                out.append(c)
            }
        }
        return out
    }

    // MARK: - Tables

    private static let maxSpokenLength = 50_000
    /// Cap on INPUT characters (comfortably above maxSpokenLength — the
    /// verbalizer usually grows text, never shrinks it much).
    static let maxInputLength = 60_000

    /// Digest hex-lengths → spoken name. Naming is by length convention:
    /// 40-hex could be a git commit, 64-hex could be BLAKE2s — "sha1 ending
    /// in 7 0 9" still identifies it either way.
    private static let hashNames: [Int: String] = [
        32: "md5", 40: "sha1", 64: "sha256", 128: "sha512",
    ]

    private static let asciiNames: [Character: String] = [
        "`": "backtick", "~": "tilde", "#": "hash", "^": "caret",
        "_": "underscore", "\\": "backslash", "|": "pipe",
        "{": "open brace", "}": "close brace",
        "[": "open bracket", "]": "close bracket",
        "*": "star", "=": "equals", "+": "plus",
        "<": "less than", ">": "greater than",
        "$": "dollar", "%": "percent", "&": "ampersand", "@": "at sign",
        "(": "open paren", ")": "close paren",
        ":": "colon", ";": "semicolon", "/": "slash", "-": "dash",
        ".": "dot", ",": "comma", "!": "exclamation", "?": "question mark",
        "'": "apostrophe", "\"": "quote",
    ]

    private static let unicodeExtras: [Character: String] = [
        "→": "arrow", "←": "left arrow", "•": "bullet",
    ]

    /// The symbols TTS most often drops silently — spoken even at .some.
    private static let someSymbols: [Character] = [
        "`", "~", "#", "^", "_", "\\", "|", "{", "}", "[", "]",
    ]

    /// Prose punctuation the voice handles with natural pausing — raw at
    /// .most, spoken only at .all.
    private static let prosePunctuation: Set<Character> = [
        ".", ",", "!", "?", "'", "\"", "(", ")", ":", ";", "-", "/",
    ]

    /// Code digraphs, active at .most and .all.
    private static let digraphs: [(key: String, name: String)] = [
        ("->", "arrow"), ("=>", "fat arrow"), ("==", "double equals"),
        ("!=", "not equals"), ("<=", "less or equal"), (">=", "greater or equal"),
        ("::", "double colon"),
    ]

    private static func isPunctuationOrSymbol(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first else { return false }
        switch s.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation,
             .closePunctuation, .initialPunctuation, .finalPunctuation,
             .otherPunctuation, .mathSymbol, .currencySymbol,
             .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }
}
