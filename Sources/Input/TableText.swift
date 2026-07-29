import Foundation

/// Pure text assembly for harvested document tables — the AX walk finds
/// them (`KeyboardMonitor.collectTableTexts`), this composes what they say.
///
/// A document body's AX value ends where an embedded object begins: the
/// text story represents a table by at most a single U+FFFC attachment
/// anchor, and the table's actual content is published as a SEPARATE
/// AXTable subtree the single-value harvest never visits. Pages read the
/// body and went silent at the table (field 2026-07-29) — seamlessly,
/// because the sanitizer strips the anchor char before speech.
///
/// Tables are APPENDED after the body rather than spliced at their
/// anchors: appending keeps the body prefix byte-identical, so every
/// AX-derived offset (selection, pointer, caret, visible range, heading
/// lines) stays valid — a splice would shift them all, and an anchor
/// doesn't say whether it holds a table or an image, so blind splicing
/// risks silently reordering content. For a body-then-table document the
/// two are identical anyway.
enum TableText {
    /// One table's spoken text: cells joined ", " so a row reads as one
    /// line, rows joined by newline so `j`/`k` walk rows. Empty cells
    /// and rows vanish — a sparse table speaks only what it holds — and
    /// so does span boilerplate.
    static func compose(rows: [[String]]) -> String {
        rows.map { row in
            row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !isSpanBoilerplate($0) }
                .joined(separator: ", ")
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    /// AX span chatter a MERGED cell publishes beside its content —
    /// "spans four rows", "spans 2 columns and 3 rows" — platform
    /// vocabulary, not document text, and the reader wants the content
    /// (field 2026-07-29, first working Pages table read). Digits or
    /// number words; optional trailing period.
    private static let spanClause =
        #"spans \S{1,12}( \S{1,12})? (rows?|columns?)"#
        + #"( and \S{1,12}( \S{1,12})? (rows?|columns?))?\.?"#

    /// Whole-cell (or whole-line) match, trimmed — real prose containing
    /// the word "spans" mid-sentence is never touched.
    static func isSpanBoilerplate(_ cell: String) -> Bool {
        cell.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: "^" + spanClause + "$",
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Strip span chatter wherever it rides inside one cell string: a
    /// line of its own, or a trailing clause glued after the content
    /// ("Ada spans four rows") — the shapes a merged cell's description
    /// leaf takes once carriers join it to the content (field
    /// 2026-07-29 round two: the whole-cell filter alone still spoke
    /// it). The trailing scrub requires whitespace before "spans", so
    /// words like "wingspans" survive; mid-sentence prose is untouched.
    static func scrubSpanChatter(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        lines.removeAll { isSpanBoilerplate($0) }
        var joined = lines.joined(separator: "\n")
        if let tail = joined.range(
               of: #"(\s+"# + spanClause + #")+\s*$"#,
               options: [.regularExpression, .caseInsensitive]) {
            joined = String(joined[..<tail.lowerBound])
        }
        return joined
    }

    /// The document text with its tables appended, blank-line separated
    /// so each table is its own paragraph block for `{`/`}`. The document
    /// prefix is never touched (offsets index it); no tables returns it
    /// byte-identical, and a table-only harvest is just the tables.
    static func merged(document: String, tables: [String]) -> String {
        let extras = tables
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !extras.isEmpty else { return document }
        guard !document.isEmpty else { return extras.joined(separator: "\n\n") }
        return document + "\n\n" + extras.joined(separator: "\n\n")
    }

    /// Characters the tables would add — the thin-harvest floor counts
    /// body + tables together, so a document that is MOSTLY table (a
    /// title box beside a big table) no longer reads as "thin".
    static func totalLength(_ tables: [String]) -> Int {
        tables.reduce(0) { $0 + $1.count }
    }
}
