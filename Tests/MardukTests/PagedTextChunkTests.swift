import XCTest
@testable import marduk

/// The synthetic-page chunker behind windowed long reads: huge plain text
/// splits into ~3k-char pages that ride the PDF paging machinery. The
/// invariants that matter: joined pages are BYTE-IDENTICAL to the input
/// (no invented paragraph breaks — `{`/`}` motions see only real ones),
/// no cut ever severs a grapheme cluster, the exact start offset survives
/// the two-part split, and every page of any size document is reachable
/// through the window math.
final class PagedTextChunkTests: XCTestCase {

    // MARK: - Round-trip byte identity

    func testChunkRoundTripsByteIdentical() {
        let text = "First paragraph with words.\n\n"
            + "Second paragraph, longer, with several sentences. More here.\n"
            + "A single-newline line.\n\n\n"
            + "Triple-newline run above. Trailing text without a final newline"
        XCTAssertEqual(PagedText.chunkPages(text, targetPageSize: 40).joined(), text)
        XCTAssertEqual(PagedText.chunkPages(text, targetPageSize: 7).joined(), text)
        XCTAssertEqual(PagedText.chunkPages(text).joined(), text)
    }

    func testChunkRoundTripsCRLF() {
        let text = "para one line a\r\npara one line b\r\n\r\npara two\r\n\r\npara three"
        for target in [10, 20, 25, 1_000] {
            XCTAssertEqual(PagedText.chunkPages(text, targetPageSize: target).joined(),
                           text, "target \(target)")
        }
    }

    // MARK: - Cut preferences

    func testChunkSplitsAtParagraphBoundaries() {
        let paragraph = String(repeating: "sentence here. ", count: 40) + "\n\n"  // ~600
        let text = String(repeating: paragraph, count: 30)
        let pages = PagedText.chunkPages(text, targetPageSize: 3_000)
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages.joined(), text)
        for page in pages {
            XCTAssertTrue(page.hasSuffix("\n\n"),
                          "cuts should land after the blank-line runs")
        }
    }

    func testChunkNewlineFallback() {
        // No blank lines anywhere — cuts fall back to line boundaries
        let text = String(repeating: "a scrollback line of output\n", count: 500)
        let pages = PagedText.chunkPages(text, targetPageSize: 3_000)
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages.joined(), text)
        for page in pages {
            XCTAssertTrue(page.hasSuffix("\n"), "cuts should land after newlines")
        }
    }

    func testChunkHardCutPathological() {
        // Minified-JS shape: no newlines at all
        let text = String(repeating: "x", count: 200_000)
        let pages = PagedText.chunkPages(text, targetPageSize: 3_000)
        XCTAssertEqual(pages.joined(), text)
        for page in pages.dropLast() {
            XCTAssertEqual(page.utf16.count, 3_000, "hard cuts land at target size")
        }
    }

    func testEveryPageStaysWithinTarget() {
        let mixed = "intro\n\n" + String(repeating: "line\n", count: 200)
            + String(repeating: "y", count: 10_000)
        for target in [50, 500, 3_000] {
            for page in PagedText.chunkPages(mixed, targetPageSize: target) {
                XCTAssertLessThanOrEqual(page.utf16.count, target)
                XCTAssertFalse(page.isEmpty)
            }
        }
    }

    // MARK: - Grapheme safety

    func testChunkGraphemeSafetyOnHardCuts() {
        // Surrogate pairs must never split: 😀 is one pair (2 units), and
        // an odd target puts every tentative cut mid-pair — all must snap.
        let smileys = String(repeating: "😀", count: 5_000)
        let smileyPages = PagedText.chunkPages(smileys, targetPageSize: 3_001)
        XCTAssertGreaterThan(smileyPages.count, 1)
        XCTAssertEqual(smileyPages.joined(), smileys)
        for page in smileyPages {
            XCTAssertEqual((page as NSString).length % 2, 0, "severed surrogate pair")
        }
        // ZWJ/VS/RI clusters: byte-identical round-trip plus surrogate
        // integrity at every page edge — cluster granularity beyond pairs
        // is Foundation's call, identity is not.
        for cluster in ["👨‍👩‍👧‍👦", "🏳️‍🌈", "🇺🇸"] {
            let text = String(repeating: cluster, count: 2_000)
            let pages = PagedText.chunkPages(text, targetPageSize: 3_000)
            XCTAssertEqual(pages.joined(), text, cluster)
            for page in pages {
                let ns = page as NSString
                XCTAssertFalse(CFStringIsSurrogateLowCharacter(ns.character(at: 0)),
                               "\(cluster): a page starts mid-pair")
                XCTAssertFalse(
                    CFStringIsSurrogateHighCharacter(ns.character(at: ns.length - 1)),
                    "\(cluster): a page ends mid-pair")
            }
        }
    }

    func testChunkTinyTargetNeverEmptyAlwaysTerminates() {
        let text = "👨‍👩‍👧‍👦ab\ncd"
        for target in [0, 1, 2, 3] {  // below one cluster's UTF-16 size
            let pages = PagedText.chunkPages(text, targetPageSize: target)
            XCTAssertEqual(pages.joined(), text, "target \(target)")
            XCTAssertFalse(pages.contains(where: \.isEmpty), "target \(target)")
        }
    }

    // MARK: - Two-part exact start

    func testChunkingTwoPartPreservesStart() {
        let prefixText = String(repeating: "before the caret. ", count: 400)  // ~7.2k
        let suffixText = "STARTWORD and everything after it. "
            + String(repeating: "tail content here. ", count: 400)
        let text = prefixText + suffixText
        let start = (prefixText as NSString).length
        let (paged, startPage) = PagedText.chunking(text, from: start)
        XCTAssertEqual(paged.text, text, "empty joiner keeps text byte-identical")
        XCTAssertTrue(paged.pages[startPage - 1].hasPrefix("STARTWORD"),
                      "the start page begins exactly at the start offset")
        XCTAssertEqual(paged.pageStarts[startPage - 1], start)
        XCTAssertEqual(paged.pages[..<(startPage - 1)].joined(), prefixText,
                       "pre-start text is fully retained (gg reaches the true top)")
    }

    func testChunkingStartEdges() {
        let text = String(repeating: "words in the document. ", count: 500)
        let length = (text as NSString).length

        let (fromTop, topPage) = PagedText.chunking(text, from: 0)
        XCTAssertEqual(topPage, 1)
        XCTAssertEqual(fromTop.text, text)

        let (fromEnd, endPage) = PagedText.chunking(text, from: length)
        XCTAssertEqual(endPage, fromEnd.pageCount)
        XCTAssertEqual(fromEnd.text, text)

        let (clamped, clampedPage) = PagedText.chunking(text, from: length + 999)
        XCTAssertEqual(clampedPage, clamped.pageCount)
    }

    func testChunkingStartInsideSurrogatePairSnaps() {
        let text = String(repeating: "😀", count: 5_000)  // 2 UTF-16 units each
        let (paged, startPage) = PagedText.chunking(text, from: 4_001)  // mid-pair
        XCTAssertEqual(paged.text, text)
        XCTAssertEqual(paged.pageStarts[startPage - 1] % 2, 0,
                       "start must snap down to a cluster boundary")
    }

    // MARK: - Degenerate inputs

    func testChunkDegenerates() {
        XCTAssertEqual(PagedText.chunkPages(""), [])
        XCTAssertEqual(PagedText.chunkPages("x"), ["x"])
        let newlines = String(repeating: "\n", count: 100)
        XCTAssertEqual(PagedText.chunkPages(newlines, targetPageSize: 7).joined(),
                       newlines)

        let (empty, page) = PagedText.chunking("", from: 0)
        XCTAssertEqual(empty.pageCount, 1)  // never a pageless document
        XCTAssertEqual(page, 1)
    }

    // MARK: - Empty-joiner invariants

    func testEmptyJoinerOffsetsContiguous() {
        let text = String(repeating: "some words here.\n", count: 2_000)
        let (paged, _) = PagedText.chunking(text, from: 5_000)
        for i in 0..<(paged.pageCount - 1) {
            XCTAssertEqual(paged.pageStarts[i + 1],
                           paged.pageStarts[i] + (paged.pages[i] as NSString).length,
                           "contiguous pages: no phantom join length")
        }
        // Boundary convention: a page-start offset belongs to that page
        XCTAssertEqual(paged.pageIndex(at: paged.pageStarts[3]), 3)
        XCTAssertEqual(paged.pageIndex(at: paged.pageStarts[3] - 1), 2)
    }

    func testWindowInheritsJoiner() {
        // Same pages, different joiners: the empty joiner packs one more
        // 10-char page into a 30-char budget than "\n\n" (12 vs 10 each)
        let pages = (0..<6).map { String(repeating: "\($0)", count: 10) }
        let pdfStyle = PagedText(pages: pages)             // "\n\n"
        let chunked = PagedText(pages: pages, joiner: "")
        XCTAssertEqual(pdfStyle.window(startingAt: 0, budget: 30).window.pageCount, 2)
        XCTAssertEqual(chunked.window(startingAt: 0, budget: 30).window.pageCount, 3)

        // A chunked window's text is an exact substring of the document
        let doc = PagedText.chunking(String(repeating: "line of text\n", count: 5_000),
                                     from: 0).paged
        let (first, window) = doc.window(startingAt: 8)
        XCTAssertEqual(first, 8)
        let expected = (doc.text as NSString)
            .substring(with: NSRange(location: doc.pageStarts[first],
                                     length: (window.text as NSString).length))
        XCTAssertEqual(window.text, expected)
    }

    // MARK: - Window chaining (continuation coverage)

    func testNextWindowStartEdges() {
        let doc = PagedText(pages: (0..<10).map { "page \($0) content" })
        XCTAssertEqual(doc.nextWindowStart(afterWindowFirst: 0, windowPageCount: 4), 4)
        XCTAssertEqual(doc.nextWindowStart(afterWindowFirst: 4, windowPageCount: 4), 8)
        XCTAssertNil(doc.nextWindowStart(afterWindowFirst: 8, windowPageCount: 2))
        XCTAssertNil(doc.nextWindowStart(afterWindowFirst: 0, windowPageCount: 10))
        let single = PagedText(pages: ["only page"])
        XCTAssertNil(single.nextWindowStart(afterWindowFirst: 0, windowPageCount: 1))
    }

    func testWindowChainingCoversTheWholeDocument() {
        // Natural continuation walks window after window: every page must
        // appear exactly once, and the chain must terminate.
        let doc = PagedText.chunking(
            String(repeating: "scrollback output line here\n", count: 8_000),
            from: 0).paged  // ~224k chars, ~75 pages
        var covered = 0
        var start: Int? = 0
        var chains = 0
        while let s = start {
            let (first, window) = doc.window(startingAt: s)
            XCTAssertEqual(first, s, "chained window must start where asked")
            covered += window.pageCount
            start = doc.nextWindowStart(afterWindowFirst: first,
                                        windowPageCount: window.pageCount)
            chains += 1
            XCTAssertLessThan(chains, 1_000, "chain must terminate")
        }
        XCTAssertEqual(covered, doc.pageCount, "no page skipped or repeated")
        XCTAssertGreaterThan(chains, 1, "test must actually exercise chaining")
    }

    // MARK: - Motions on window text

    func testMotionsWorkOnChunkedWindowText() {
        // The window text of a chunked doc contains only ORIGINAL paragraph
        // breaks — motions land on real boundaries, never on page seams.
        let paragraph = String(repeating: "word here. ", count: 30) + "\n\n"
        let doc = PagedText.chunking(String(repeating: paragraph, count: 300),
                                     from: 0).paged
        let (_, window) = doc.window(startingAt: 5)
        let text = window.text
        let mid = (text as NSString).length / 2
        let fwd = ReadNavigator.target(in: text, from: mid,
                                       unit: .paragraph, direction: .forward)
        XCTAssertGreaterThan(fwd, mid)
        let paraLength = (paragraph as NSString).length
        XCTAssertEqual((fwd - ReadNavigator.target(in: text, from: fwd,
                                                   unit: .paragraph,
                                                   direction: .forward))
                        .magnitude % UInt(paraLength), 0,
                       "paragraph targets land on real paragraph starts")
    }

    // MARK: - Deterministic property sweep

    func testChunkPropertySweep() {
        // Seeded LCG — reproducible pseudo-random mixes of prose, newline
        // runs, and emoji. Invariants: round-trip identity, no empty page,
        // page-size bound, contiguous offsets under the empty joiner.
        var seed: UInt64 = 0x5DEECE66D
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33) % bound
        }
        let blocks = ["lorem ipsum dolor ", "word. ", "\n", "\n\n", "👨‍👩‍👧‍👦", "🇺🇸x",
                      "line\r\n", "\r\n\r\n", "unbrokenrunofletters"]
        for round in 0..<40 {
            var text = ""
            for _ in 0..<(20 + next(200)) {
                text += blocks[next(blocks.count)]
            }
            let target = 8 + next(300)
            let pages = PagedText.chunkPages(text, targetPageSize: target)
            XCTAssertEqual(pages.joined(), text, "round \(round) target \(target)")
            XCTAssertFalse(pages.contains(where: \.isEmpty), "round \(round)")
            let start = next((text as NSString).length + 1)
            let (paged, startPage) = PagedText.chunking(text, from: start,
                                                        targetPageSize: target)
            XCTAssertEqual(paged.text, text, "round \(round) start \(start)")
            XCTAssertTrue((1...paged.pageCount).contains(startPage), "round \(round)")
            for i in 0..<(paged.pageCount - 1) {
                XCTAssertEqual(paged.pageStarts[i + 1],
                               paged.pageStarts[i] + (paged.pages[i] as NSString).length)
            }
        }
    }
}
