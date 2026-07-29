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
    /// and rows vanish — a sparse table speaks only what it holds.
    static func compose(rows: [[String]]) -> String {
        rows.map { row in
            row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
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
