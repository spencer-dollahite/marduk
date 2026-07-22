import Foundation
import NaturalLanguage

/// Units and directions for in-read navigation (vim-style read motions).
enum ReadUnit { case word, sentence, line, paragraph }
enum ReadDirection { case back, forward }

/// The vim-markdown header family: ]] / [[ next/previous heading (any
/// level), ][ / [] next/previous same-level sibling, ]u parent.
enum HeadingMotion { case next, previous, nextSibling, previousSibling, parent }

/// A heading position in a read. `offset` is an abstract ascending
/// ordinal — a UTF-16 offset into the processed read text on plain
/// reads, a global page index on paged (PDF outline) reads — so the
/// same motion math serves both.
struct ReadHeading: Equatable {
    let offset: Int
    let level: Int
}

/// Pure boundary math for navigating within a read's text. All positions are
/// UTF-16 offsets — the same coordinates AVSpeechSynthesizer reports in
/// willSpeakRangeOfSpeechString, so the engine's tracked position plugs in
/// directly. No state, no AV dependencies: unit-testable on its own.
enum ReadNavigator {

    /// A repeated back motion must travel, not restart the same unit: within
    /// this many UTF-16 units of a unit's start, "back" targets the PREVIOUS
    /// unit instead. Word grace is 0 because boundary callbacks sit exactly
    /// on word starts — back from a word's own start is always the previous
    /// word — while sentences/paragraphs need a couple of words of slack or
    /// tapping `(` twice quickly would restart the same sentence forever.
    private static func grace(for unit: ReadUnit) -> Int {
        switch unit {
        case .word: return 0
        case .sentence: return 12
        case .line: return 12
        case .paragraph: return 24
        }
    }

    /// The offset a jump should re-speak from. Back: the start of the unit
    /// containing `position` (or the previous unit within the grace window).
    /// Forward: the start of the next unit. Both clamp to the text: back
    /// bottoms out at 0, forward past the last unit returns `position`
    /// unchanged — callers treat an unmoved target as a no-op edge.
    static func target(in text: String, from position: Int,
                       unit: ReadUnit, direction: ReadDirection) -> Int {
        let position = max(0, min(position, (text as NSString).length))
        let starts = unitStarts(in: text, unit: unit)
        guard !starts.isEmpty else { return position } // nothing to land on — no-op

        switch direction {
        case .back:
            // Last unit starting at or before the position — a position in
            // the whitespace between units belongs to the preceding one.
            guard let idx = starts.lastIndex(where: { $0 <= position }) else {
                return 0
            }
            if position - starts[idx] <= grace(for: unit), idx > 0 {
                return starts[idx - 1]
            }
            return starts[idx]

        case .forward:
            return starts.first(where: { $0 > position }) ?? position
        }
    }

    /// Vim-style in-read search. Smartcase: an all-lowercase query matches
    /// case-insensitively, any capital makes it exact. No wraparound — audio
    /// gives no cue that a jump wrapped, so an exhausted direction is nil.
    /// A hit returns the start of the SENTENCE containing the match, giving
    /// the found term a few words of runway instead of blurting it cold.
    static func searchTarget(in text: String, from position: Int,
                             query: String, direction: ReadDirection) -> Int? {
        guard !query.isEmpty else { return nil }
        let ns = text as NSString
        let position = max(0, min(position, ns.length))

        var options: NSString.CompareOptions = []
        if query == query.lowercased() { options.insert(.caseInsensitive) }

        let range: NSRange
        switch direction {
        case .forward:
            // From one past the current word start, so the word being
            // spoken right now never matches itself.
            let from = min(position + 1, ns.length)
            range = NSRange(location: from, length: ns.length - from)
        case .back:
            options.insert(.backwards)
            range = NSRange(location: 0, length: position)
        }

        let match = ns.range(of: query, options: options, range: range)
        guard match.location != NSNotFound else { return nil }

        let sentences = unitStarts(in: text, unit: .sentence)
        return sentences.last(where: { $0 <= match.location }) ?? match.location
    }

    /// Vim G scaled to listening: the start of the last paragraph — the
    /// read's ending with its lead-in. (gg is simply offset 0.)
    static func endTarget(in text: String) -> Int {
        unitStarts(in: text, unit: .paragraph).last ?? 0
    }

    /// Whole-number percent (0-100) of a position through a length —
    /// the number vim's Ctrl+G ruler shows, rounded and clamped.
    static func percent(_ position: Int, of length: Int) -> Int {
        guard length > 0 else { return 0 }
        return max(0, min(100, Int((Double(position) * 100 / Double(length)).rounded())))
    }

    /// Vim f/F: the next/previous occurrence of `char` strictly after/
    /// before `position` — case-sensitive, like vim. Nil when the
    /// direction is exhausted (no wrap, same as search).
    static func findChar(in text: String, from position: Int,
                         char: Character, direction: ReadDirection) -> Int? {
        let ns = text as NSString
        let position = max(0, min(position, ns.length))
        let range: NSRange
        var options: NSString.CompareOptions = []
        switch direction {
        case .forward:
            let from = min(position + 1, ns.length)
            range = NSRange(location: from, length: ns.length - from)
        case .back:
            options.insert(.backwards)
            range = NSRange(location: 0, length: position)
        }
        let match = ns.range(of: String(char), options: options, range: range)
        return match.location == NSNotFound ? nil : match.location
    }

    /// Start of the word containing `position` — where a char-find hit
    /// respeaks from, so the found character arrives inside its word
    /// instead of mid-syllable.
    static func wordStart(in text: String, at position: Int) -> Int {
        let clamped = max(0, min(position, (text as NSString).length))
        return unitStarts(in: text, unit: .word)
            .last(where: { $0 <= clamped }) ?? clamped
    }

    /// The text of the word/sentence containing `position` (spell-out).
    /// A position in the gap between units belongs to the preceding one,
    /// same as the motions. Only word/sentence — the tokenized units.
    static func unitText(in text: String, at position: Int, unit: ReadUnit) -> String? {
        guard unit == .word || unit == .sentence else { return nil }
        let ns = text as NSString
        let position = max(0, min(position, ns.length))
        let tokenizer = NLTokenizer(unit: unit == .word ? .word : .sentence)
        tokenizer.string = text
        var containing: NSRange?
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let r = NSRange(range, in: text)
            if r.location <= position {
                containing = r
                return true
            }
            return false // past the position — stop walking
        }
        guard let r = containing else { return nil }
        return ns.substring(with: r)
    }

    /// Vim 0: the start of the line containing `position` — no grace, no
    /// travel; pressing it at the line's start is the caller's no-op edge.
    static func lineStart(in text: String, at position: Int) -> Int {
        let position = max(0, min(position, (text as NSString).length))
        return unitStarts(in: text, unit: .line)
            .last(where: { $0 <= position }) ?? 0
    }

    // MARK: - Headings

    /// ]] / [[ — the first heading strictly after / last strictly before
    /// `position`. Discrete like findChar: no grace, no wrap — strict
    /// comparisons already make "back from a heading you just landed on"
    /// travel to the previous one. Nil = exhausted (caller buzzes).
    /// `headings` must be ascending by offset.
    static func headingTarget(headings: [ReadHeading], from position: Int,
                              direction: ReadDirection) -> Int? {
        switch direction {
        case .forward:
            return headings.first(where: { $0.offset > position })?.offset
        case .back:
            return headings.last(where: { $0.offset < position })?.offset
        }
    }

    /// ][ / [] — the next/previous heading at the SAME level as the one
    /// containing `position`, aborting at any lower-level heading in
    /// between (siblings share a parent, vim-markdown semantics). Nil
    /// when `position` precedes every heading, when a parent boundary is
    /// crossed first, or when the direction is exhausted.
    static func siblingHeadingTarget(headings: [ReadHeading], from position: Int,
                                     direction: ReadDirection) -> Int? {
        guard let idx = headings.lastIndex(where: { $0.offset <= position }) else {
            return nil
        }
        let level = headings[idx].level
        let candidates = direction == .forward
            ? Array(headings[(idx + 1)...])
            : Array(headings[..<idx].reversed())
        for heading in candidates {
            if heading.level < level { return nil }  // crossed the parent
            if heading.level == level { return heading.offset }
        }
        return nil
    }

    /// ]u — the nearest earlier heading with a level strictly LOWER than
    /// the one containing `position` (its parent). Nil when there is no
    /// containing heading or it is already top-level.
    static func parentHeadingTarget(headings: [ReadHeading], from position: Int) -> Int? {
        guard let idx = headings.lastIndex(where: { $0.offset <= position }) else {
            return nil
        }
        let level = headings[idx].level
        return headings[..<idx].last(where: { $0.level < level })?.offset
    }

    /// UTF-16 offset where each newline-counted line begins: [0] plus the
    /// position after every \n. The exact inverse of counting newlines
    /// before an offset (KeyboardMonitor.lineIndex), which is how harvest
    /// line indices are defined — NOT the content-run starts the line
    /// motions use (those skip blank lines; this must not).
    static func lineStartOffsets(in text: String) -> [Int] {
        let ns = text as NSString
        var result = [0]
        for i in 0..<ns.length where ns.character(at: i) == 0x0A {
            result.append(i + 1)
        }
        return result
    }

    /// Harvest-line headings → processed-text offsets. Line indices come
    /// from the RAW harvest while `lineStarts` describes the PROCESSED
    /// text, so each index is clamped (preprocessing may drop the odd
    /// line — the same ±1-line drift the scroll-follow anchors accept).
    /// Collapsed duplicates keep the first entry; result is ascending.
    static func headingOffsets(lines: [(line: Int, level: Int)],
                               lineStarts: [Int]) -> [ReadHeading] {
        guard !lineStarts.isEmpty else { return [] }
        var result: [ReadHeading] = []
        for entry in lines.sorted(by: { $0.line < $1.line }) {
            let offset = lineStarts[max(0, min(entry.line, lineStarts.count - 1))]
            guard result.last?.offset != offset else { continue }
            result.append(ReadHeading(offset: offset, level: entry.level))
        }
        return result
    }

    /// UTF-16 start offsets of every unit, ascending. Words and sentences
    /// come from NLTokenizer (handles "Dr. Smith", "e.g.", "?" and "!"
    /// correctly — vim's own sentence motion isn't period-based either);
    /// lines break on every newline; paragraphs are blank-line-separated
    /// blocks (vim's definition), falling back to lines when the text has
    /// no blank lines so {/} stay useful in terminal-style output. The
    /// sanitizer normalizes \r\n → \n before text ever reaches a read, so
    /// a CRLF can't masquerade as a blank line.
    private static func unitStarts(in text: String, unit: ReadUnit) -> [Int] {
        switch unit {
        case .line:
            return lineStarts(in: text)
        case .paragraph:
            let blocks = blankLineBlockStarts(in: text)
            if blocks.count > 1 { return blocks }
            let lines = lineStarts(in: text)
            return lines.count > 1 ? lines : blocks
        case .word, .sentence:
            let tokenizer = NLTokenizer(unit: unit == .word ? .word : .sentence)
            tokenizer.string = text
            var starts: [Int] = []
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                starts.append(NSRange(range, in: text).location)
                return true
            }
            return starts
        }
    }

    private static func lineStarts(in text: String) -> [Int] {
        starts(in: text, breakRun: 1)
    }

    private static func blankLineBlockStarts(in text: String) -> [Int] {
        starts(in: text, breakRun: 2)
    }

    /// Starts of maximal content runs separated by at least `breakRun`
    /// consecutive newlines (1 = lines, 2 = blank-line paragraphs).
    private static func starts(in text: String, breakRun: Int) -> [Int] {
        let ns = text as NSString
        var result: [Int] = []
        var newlineRun = breakRun  // text start counts as a break
        for i in 0..<ns.length {
            let ch = ns.character(at: i)
            if ch == 0x0A || ch == 0x0D {
                newlineRun += 1
            } else {
                if newlineRun >= breakRun { result.append(i) }
                newlineRun = 0
            }
        }
        return result
    }
}
