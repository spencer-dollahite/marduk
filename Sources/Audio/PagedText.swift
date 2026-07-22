import Foundation
import PDFKit

/// A document read with page structure: the flat text the speech pipeline
/// already understands, plus the UTF-16 offset where each page begins —
/// pages are just respeak targets, so every reading-mode feature works
/// inside a paged read unchanged. Pages come from a real paginated source
/// (PDF) or from chunking huge plain text into synthetic pages. Pure core
/// (unit-tested); the PDFKit loader and the Preview-title parser live
/// alongside it.
struct PagedText: Equatable {
    let text: String        // pages joined with `joiner`
    let pageStarts: [Int]   // UTF-16 offset of each page start, ascending
    let pages: [String]     // retained for WINDOWING (see window(startingAt:))
    let joiner: String      // "\n\n" for PDFs (page.string lacks separators);
                            // "" for chunked text, whose pages RETAIN their
                            // own separators so text is byte-identical input

    /// One window of pages is what actually gets preprocessed and spoken —
    /// deliberately below both preprocessor caps (60k input / 50k output)
    /// so a window can never trip them.
    static let windowBudget = 45_000
    /// Target size of a synthetic page — about a printed page of text, so
    /// Ctrl+F steps feel page-like and a window holds ~15 pages.
    static let syntheticPageSize = 3_000

    /// Whether a document of this UTF-16 length needs paging at all —
    /// anything that fits one window reads plain.
    static func exceedsWindow(_ utf16Length: Int) -> Bool {
        utf16Length > windowBudget
    }

    var pageCount: Int { pageStarts.count }

    /// Total UTF-16 length of `text` without scanning it — a per-
    /// keystroke query (Ctrl+G, {count}%) must never walk a 9M-char
    /// document. Last page start + last page length, O(last page).
    var utf16Length: Int {
        guard let lastStart = pageStarts.last, let last = pages.last else { return 0 }
        return lastStart + last.utf16.count
    }

    init(pages: [String], joiner: String = "\n\n") {
        var joined = ""
        var starts: [Int] = []
        // Running UTF-16 offset, never re-measuring `joined`: bridging the
        // accumulator each iteration goes quadratic on a 3000-page chunked
        // document (the 9M-char field case).
        var offset = 0
        let joinLength = joiner.utf16.count
        for (index, page) in pages.enumerated() {
            if index > 0 {
                joined += joiner
                offset += joinLength
            }
            starts.append(offset)
            joined += page
            offset += page.utf16.count
        }
        text = joined
        pageStarts = starts
        self.pages = pages
        self.joiner = joiner
    }

    /// A contiguous page WINDOW starting at `page` (0-based, clamped),
    /// sized so preprocessing stays bounded — the whole document of a
    /// large PDF used to be processed at once, and the speech input cap
    /// then made pages past ~60k chars unreachable. Windows make every
    /// page of any size document reachable: jumps outside the current
    /// window rebuild a new one there. Always contains at least one page.
    func window(startingAt page: Int, budget: Int = PagedText.windowBudget)
        -> (firstPage: Int, window: PagedText) {
        guard !pages.isEmpty else { return (0, self) }
        let first = max(0, min(page, pageCount - 1))
        var last = first
        var total = (pages[first] as NSString).length
        let joinLength = (joiner as NSString).length
        while last + 1 < pageCount {
            let next = (pages[last + 1] as NSString).length + joinLength
            guard total + next <= budget else { break }
            total += next
            last += 1
        }
        return (first, PagedText(pages: Array(pages[first...last]), joiner: joiner))
    }

    /// Global first page of the window after one starting at `first` with
    /// `count` pages — nil when that window already reaches the document's
    /// end. Pure math for the natural window continuation at utterance end.
    func nextWindowStart(afterWindowFirst first: Int, windowPageCount count: Int) -> Int? {
        let next = first + count
        return next < pageCount ? next : nil
    }

    /// The page containing `offset` (0-based). An offset in the join
    /// between pages belongs to the preceding page, same convention as
    /// every other unit.
    func pageIndex(at offset: Int) -> Int {
        max(0, (pageStarts.lastIndex { $0 <= offset } ?? 0))
    }

    // MARK: - Synthetic pages (huge plain text)

    /// Chunk plain text into synthetic ~targetPageSize-char pages. Cut
    /// preference: just after a blank-line run (a paragraph, tolerating \r
    /// — the chunker sees RAW text, sanitize normalizes later) → just after
    /// any newline → grapheme-snapped hard cut (unbroken runs only). Pages
    /// RETAIN their separators: joined with "" the result is byte-identical
    /// to the input, so no paragraph break is ever invented and any window
    /// is an exact substring of the document. Newline cuts are grapheme-safe
    /// (a break always follows LF); hard cuts snap to composed-sequence
    /// boundaries, so no split severs a surrogate pair or emoji cluster.
    static func chunkPages(_ text: String,
                           targetPageSize: Int = syntheticPageSize) -> [String] {
        let ns = text as NSString
        let length = ns.length
        let target = max(1, targetPageSize)
        guard length > 0 else { return [] }
        var pages: [String] = []
        var pageStart = 0
        while pageStart < length {
            let tentative = min(pageStart + target, length)
            if tentative == length {
                pages.append(ns.substring(from: pageStart))
                break
            }
            let cut = cutPoint(ns, pageStart: pageStart, tentative: tentative)
            pages.append(ns.substring(with: NSRange(location: pageStart,
                                                    length: cut - pageStart)))
            pageStart = cut
        }
        return pages
    }

    /// The best page cut in (pageStart, tentative]: backward scan bounded
    /// by the page start, so the whole chunk pass stays linear.
    private static func cutPoint(_ ns: NSString, pageStart: Int, tentative: Int) -> Int {
        let lf: unichar = 0x0A, cr: unichar = 0x0D
        var newlineCut: Int?
        var i = tentative - 1
        while i > pageStart {
            guard ns.character(at: i) == lf else { i -= 1; continue }
            if newlineCut == nil { newlineCut = i + 1 }
            // Count LFs in the run of [\n\r] ending at i — ≥2 means the
            // run contains a blank line: a paragraph boundary.
            var j = i
            var lfRun = 0
            while j >= pageStart {
                let c = ns.character(at: j)
                if c == lf { lfRun += 1 } else if c != cr { break }
                j -= 1
            }
            if lfRun >= 2 { return i + 1 }
            i = j  // skip below the run; nothing in it can start a new one
        }
        if let cut = newlineCut { return cut }
        // Hard cut: snap DOWN to a grapheme boundary; always advance at
        // least one composed sequence so no page is empty.
        let cluster = ns.rangeOfComposedCharacterSequence(at: tentative)
        var cut = cluster.location < tentative ? cluster.location : tentative
        if cut <= pageStart {
            let head = ns.rangeOfComposedCharacterSequence(at: pageStart)
            cut = min(head.location + head.length, ns.length)
        }
        return cut
    }

    /// Chunk a WHOLE document while preserving an exact start offset: text
    /// before `start` and from `start` chunk separately, so the returned
    /// startPage (1-based) begins exactly at `start` — R keeps its word-
    /// start precision while gg reaches the true top (pre-caret text,
    /// unreachable on plain reads) and G the true end.
    static func chunking(_ text: String, from start: Int,
                         targetPageSize: Int = syntheticPageSize)
        -> (paged: PagedText, startPage: Int) {
        let ns = text as NSString
        var s = max(0, min(start, ns.length))
        if s > 0 && s < ns.length {
            // Defensive: AX offsets from odd apps may land mid-cluster
            let cluster = ns.rangeOfComposedCharacterSequence(at: s)
            if cluster.location < s { s = cluster.location }
        }
        let prefix = s > 0
            ? chunkPages(ns.substring(to: s), targetPageSize: targetPageSize) : []
        let suffix = s < ns.length
            ? chunkPages(ns.substring(from: s), targetPageSize: targetPageSize) : []
        var pages = prefix + suffix
        if pages.isEmpty { pages = [text] }  // never a pageless document
        let paged = PagedText(pages: pages, joiner: "")
        let startPage = min(max(prefix.count + 1, 1), paged.pageCount)
        return (paged, startPage)
    }

    /// Load a PDF's text, one entry per page, plus its outline (table of
    /// contents) flattened to heading pages — the PDF rung of the heading
    /// motions. Nil for missing files, password-locked documents, and
    /// image-only scans (no text on any page — OCR is future work). A
    /// PDF without an outline gets an empty headings array, never nil.
    static func load(url: URL)
        -> (paged: PagedText, headings: [(page: Int, level: Int)])? {
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
        let headings = document.outlineRoot.map { root in
            flattenOutline(root) { page in
                let index = document.index(for: page)
                return index >= 0 && index < document.pageCount ? index : nil
            }
        } ?? []
        fputs("[keyboard] PDF loaded: \(pages.count) pages, "
            + "\(headings.count) outline headings\n", stderr)
        return (PagedText(pages: pages), headings)
    }

    /// Flatten a PDFOutline tree to (0-based page, level) pairs, level =
    /// nesting depth from 1 (the root is a container, not a heading).
    /// Entries with no resolvable destination page are skipped. Stable-
    /// sorted ascending by page — outline order breaks ties, so a page
    /// with several entries keeps its top-of-page entry first.
    static func flattenOutline(_ root: PDFOutline,
                               pageIndex: (PDFPage) -> Int?) -> [(page: Int, level: Int)] {
        var found: [(page: Int, level: Int)] = []
        func walk(_ node: PDFOutline, depth: Int) {
            if depth > 0, let page = node.destination?.page,
               let index = pageIndex(page) {
                found.append((page: index, level: min(depth, 6)))
            }
            for i in 0..<node.numberOfChildren {
                if let child = node.child(at: i) { walk(child, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        return found.enumerated()
            .sorted { ($0.element.page, $0.offset) < ($1.element.page, $1.offset) }
            .map(\.element)
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
