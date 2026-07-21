import Foundation
import NaturalLanguage

/// Units and directions for in-read navigation (vim-style read motions).
enum ReadUnit { case word, sentence, paragraph }
enum ReadDirection { case back, forward }

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

    /// UTF-16 start offsets of every unit, ascending. Words and sentences
    /// come from NLTokenizer (handles "Dr. Smith", "e.g.", "?" and "!"
    /// correctly — vim's own sentence motion isn't period-based either);
    /// paragraphs are maximal runs separated by newlines, which matches how
    /// AX-extracted text actually breaks.
    private static func unitStarts(in text: String, unit: ReadUnit) -> [Int] {
        if unit == .paragraph { return paragraphStarts(in: text) }
        let tokenizer = NLTokenizer(unit: unit == .word ? .word : .sentence)
        tokenizer.string = text
        var starts: [Int] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            starts.append(NSRange(range, in: text).location)
            return true
        }
        return starts
    }

    private static func paragraphStarts(in text: String) -> [Int] {
        let ns = text as NSString
        var starts: [Int] = []
        var inParagraph = false
        for i in 0..<ns.length {
            let ch = ns.character(at: i)
            let isNewline = ch == 0x0A || ch == 0x0D
            if isNewline {
                inParagraph = false
            } else if !inParagraph {
                starts.append(i)
                inParagraph = true
            }
        }
        return starts
    }
}
