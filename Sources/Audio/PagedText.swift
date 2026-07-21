import Foundation
import PDFKit

/// A document read with page structure: the flat text the speech pipeline
/// already understands, plus the UTF-16 offset where each page begins —
/// pages are just respeak targets, so every reading-mode feature works
/// inside a paged read unchanged. Pure core (unit-tested); the PDFKit
/// loader and the Preview-title parser live alongside it.
struct PagedText: Equatable {
    let text: String        // pages joined with "\n\n" (paragraph breaks)
    let pageStarts: [Int]   // UTF-16 offset of each page start, ascending

    var pageCount: Int { pageStarts.count }

    init(pages: [String]) {
        var joined = ""
        var starts: [Int] = []
        for (index, page) in pages.enumerated() {
            if index > 0 { joined += "\n\n" }
            starts.append((joined as NSString).length)
            joined += page
        }
        text = joined
        pageStarts = starts
    }

    /// The page containing `offset` (0-based). An offset in the join
    /// between pages belongs to the preceding page, same convention as
    /// every other unit.
    func pageIndex(at offset: Int) -> Int {
        max(0, (pageStarts.lastIndex { $0 <= offset } ?? 0))
    }

    /// Load a PDF's text, one entry per page. Nil for missing files,
    /// password-locked documents, and image-only scans (no text on any
    /// page — OCR is future work).
    static func load(url: URL) -> PagedText? {
        guard let document = PDFDocument(url: url), !document.isLocked,
              document.pageCount > 0 else {
            fputs("[keyboard] PDF load failed or locked: \(url.lastPathComponent)\n", stderr)
            return nil
        }
        let pages = (0..<document.pageCount).map {
            document.page(at: $0)?.string ?? ""
        }
        guard pages.contains(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            fputs("[keyboard] PDF has no extractable text (scanned?): "
                + "\(url.lastPathComponent)\n", stderr)
            return nil
        }
        fputs("[keyboard] PDF loaded: \(pages.count) pages\n", stderr)
        return PagedText(pages: pages)
    }

    /// Preview window titles read "Name — Page 3 of 12" — the visible
    /// page, used as the read's start position. Returns the 1-BASED page
    /// number; nil when the title doesn't match (localized Preview, other
    /// viewers) — callers start at page 1.
    static func previewPage(fromTitle title: String) -> Int? {
        guard let range = title.range(of: #"Page (\d+) of \d+"#,
                                      options: .regularExpression) else {
            return nil
        }
        let digits = title[range].dropFirst(5).prefix { $0.isNumber }
        return Int(digits)
    }
}
