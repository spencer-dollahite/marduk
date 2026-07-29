import XCTest
import AppKit
import CoreText
import PDFKit
@testable import marduk

/// Real-artifact seed suite: genuine file formats through the shipping
/// pipelines, headless — the slice of "test on real things" CI can
/// honestly run. Hosted runners can't grant Accessibility TCC and don't
/// ship iWork or drive other apps' AX trees, so real-app AX stays a
/// hardware concern; real DOCUMENTS don't: real prose rides the chunker,
/// the navigator, and the preprocessor; a genuine PDF (drawn with
/// CoreText, parsed by PDFKit) rides the paged loader; genuine RTF rides
/// the heading detector.
///
/// Fixtures/frankenstein-excerpt.txt is the opening ~120k chars of Mary
/// Shelley's Frankenstein (Project Gutenberg #84, public domain) — real
/// sentence rhythm, real blank-line paragraph structure, no synthetic
/// lorem shapes.
final class RealDocumentTests: XCTestCase {

    private static let prose: String = {
        guard let url = Bundle.module.url(forResource: "frankenstein-excerpt",
                                          withExtension: "txt",
                                          subdirectory: "Fixtures"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return text
    }()

    func testFixtureIsRealProse() {
        let prose = Self.prose
        XCTAssertGreaterThan(prose.count, 100_000, "fixture must have loaded")
        XCTAssertTrue(prose.contains("Frankenstein"))
        XCTAssertTrue(prose.contains("Elizabeth"))
        XCTAssertGreaterThan(prose.components(separatedBy: "\n\n").count, 100,
                             "real paragraph structure, not one blob")
    }

    // MARK: chunking + windowing on a real document

    func testRealProseChunkingIsByteIdentical() {
        let prose = Self.prose
        let ns = prose as NSString
        XCTAssertTrue(PagedText.exceedsWindow(ns.length),
                      "the excerpt exercises the paged path for real")

        let start = ReadNavigator.wordStart(in: prose, at: ns.length / 3)
        let (paged, startPage) = PagedText.chunking(prose, from: start)
        XCTAssertEqual(paged.text, prose, "joiner is empty — nothing invented")
        XCTAssertEqual(paged.utf16Length, ns.length)
        XCTAssertEqual(paged.pageStarts[startPage - 1], start,
                       "the caret page begins exactly at the computed start")
        XCTAssertEqual(paged.pageStarts.first, 0, "gg reaches the true top")
        XCTAssertTrue(zip(paged.pageStarts, paged.pageStarts.dropFirst())
                        .allSatisfy { $0.0 < $0.1 }, "page starts strictly ascend")
        XCTAssertGreaterThan(paged.pageCount, 30)

        let (first, window) = paged.window(startingAt: startPage - 1)
        XCTAssertLessThanOrEqual(first, startPage - 1)
        XCTAssertLessThanOrEqual((window.text as NSString).length,
                                 PagedText.windowBudget
                                     + PagedText.syntheticPageSize,
                                 "a window stays near budget")
    }

    // MARK: reading motions over real prose

    func testRealProseMotionsTravel() {
        let prose = Self.prose
        let ns = prose as NSString

        // Sentence-back walks a real 30k slice all the way to the top —
        // the grace window must make repeated taps TRAVEL, never loop.
        let slice = ns.substring(to: 30_000)
        var pos = (slice as NSString).length - 1
        var hops = 0
        while pos > 0, hops < 3_000 {
            let next = ReadNavigator.target(in: slice, from: pos,
                                            unit: .sentence, direction: .back)
            guard next < pos else { break }
            pos = next
            hops += 1
        }
        XCTAssertEqual(pos, 0, "sentence-back reaches the top of real prose")
        XCTAssertGreaterThan(hops, 50, "real prose has real sentence density")

        // Paragraph-forward crosses the whole excerpt's blank-line blocks.
        pos = 0
        hops = 0
        while hops < 3_000 {
            let next = ReadNavigator.target(in: prose, from: pos,
                                            unit: .paragraph, direction: .forward)
            guard next > pos else { break }  // no-op edge = the end
            pos = next
            hops += 1
        }
        XCTAssertGreaterThan(hops, 100)
        XCTAssertGreaterThan(pos, ns.length * 9 / 10,
                             "forward travel reaches the last blocks")
    }

    func testRealProseSearchLandsOnASentenceStart() throws {
        let prose = Self.prose
        // Smartcase, lowercase query: matches "Elizabeth" case-insensitively.
        let hit = try XCTUnwrap(ReadNavigator.searchTarget(
            in: prose, from: 0, query: "elizabeth", direction: .forward))
        XCTAssertGreaterThan(hit, 0)
        let sentence = try XCTUnwrap(ReadNavigator.unitText(
            in: prose, at: hit, unit: .sentence))
        XCTAssertTrue(sentence.localizedCaseInsensitiveContains("elizabeth"),
                      "the landing sentence contains the match (context runway)")
    }

    // MARK: real prose through the speech preprocessor

    func testRealProseSurvivesThePreprocessor() {
        let ns = Self.prose as NSString
        // Real prose laced with the invisible junk real clipboards carry —
        // including the attachment anchor a document with embedded objects
        // leaves behind (the table-rung field case).
        let dirty = ns.substring(to: 20_000) + "\u{FFFC}\u{200B}\u{FEFF} tail after junk"
        let out = SpeechPreprocessor.process(dirty, settings: .default)
        XCTAssertFalse(out.isEmpty)
        XCTAssertFalse(out.unicodeScalars.contains {
            $0.value == 0xFFFC || $0.value == 0x200B || $0.value == 0xFEFF
        }, "sanitize strips anchors and invisibles from real text")
        XCTAssertTrue(out.contains("tail after junk"),
                      "text after the junk still speaks")

        // The whole 120k excerpt respects the input cap end to end.
        let capped = SpeechPreprocessor.process(Self.prose, settings: .default)
        XCTAssertFalse(capped.isEmpty)
        XCTAssertLessThanOrEqual(capped.utf16.count,
                                 SpeechPreprocessor.maxInputLength)
    }

    // MARK: a genuine PDF through the shipping loader

    /// Draw real text into a real PDF file with CoreText — actual text
    /// operators, so PDFKit extraction is the true shipping path, not a
    /// mock. Headless-safe (no window server involvement).
    private func makePDF(pages: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("marduk-real-doc-\(UUID().uuidString).pdf")
        let mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        var box = mediaBox
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw XCTSkip("no CGPDFContext on this runner")
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        for page in pages {
            ctx.beginPDFPage(nil)
            let attributed = NSAttributedString(
                string: page,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let path = CGPath(rect: mediaBox.insetBy(dx: 40, dy: 40),
                              transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    func testRealPDFThroughTheShippingLoader() throws {
        let ns = Self.prose as NSString
        var pages: [String] = (0..<5).map { i in
            "MARDUKPAGE\(i).\n"
                + ns.substring(with: NSRange(location: i * 8_000, length: 1_200))
        }
        // A table-shaped page: PDF tables are just text, and the paged
        // read must carry them like any other page.
        pages.append("MARDUKPAGE5.\nName\tRole\n"
            + "Ada Lovelace\tAnalyst\nGrace Hopper\tAdmiral\n")

        let url = try makePDF(pages: pages)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try XCTUnwrap(PagedText.load(url: url),
                                   "the shipping loader reads the real file")
        XCTAssertEqual(loaded.paged.pageCount, 6)
        for i in 0..<6 {
            XCTAssertTrue(loaded.paged.pages[i].contains("MARDUKPAGE\(i)"),
                          "page \(i) extracted, in order")
        }
        XCTAssertTrue(loaded.paged.pages[5].contains("Lovelace"))
        XCTAssertTrue(loaded.headings.isEmpty, "no outline was written")

        // Page window math on the real load, and the Preview title shape.
        let (first, window) = loaded.paged.window(startingAt: 5)
        XCTAssertLessThanOrEqual(first, 5)
        XCTAssertTrue(window.pages.contains { $0.contains("MARDUKPAGE5") })
        XCTAssertEqual(PagedText.previewPage(fromTitle: "doc.pdf — Page 4 of 6"), 4)
    }

    func testRealPDFOutlineFlattens() throws {
        let url = try makePDF(pages: (0..<5).map { "MARDUKPAGE\($0)." })
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(PDFDocument(url: url))

        func entry(page: Int) throws -> PDFOutline {
            let node = PDFOutline()
            node.destination = PDFDestination(
                page: try XCTUnwrap(document.page(at: page)),
                at: NSPoint(x: 0, y: 792))
            return node
        }
        let root = PDFOutline()
        let chapterOne = try entry(page: 0)
        let chapterTwo = try entry(page: 3)
        root.insertChild(chapterOne, at: 0)
        root.insertChild(chapterTwo, at: 1)
        chapterTwo.insertChild(try entry(page: 4), at: 0)

        let flat = PagedText.flattenOutline(root) { page in
            let index = document.index(for: page)
            return index >= 0 ? index : nil
        }
        XCTAssertEqual(flat.map(\.page), [0, 3, 4])
        XCTAssertEqual(flat.map(\.level), [1, 1, 2],
                       "nesting depth ranks as heading level")
    }

    // MARK: genuine RTF through the heading detector

    func testRealRTFHeadingDetection() throws {
        let attributed = NSMutableAttributedString()
        func append(_ text: String, size: CGFloat) {
            attributed.append(NSAttributedString(
                string: text,
                attributes: [.font: NSFont(name: "Helvetica", size: size)
                    ?? NSFont.systemFont(ofSize: size)]))
        }
        append("Chapter One\n", size: 24)
        append(String(repeating: "Real body text for the detector. ",
                      count: 20), size: 12)
        append("A Later Section\n", size: 18)
        append(String(repeating: "More body follows the section. ",
                      count: 20), size: 12)

        // Round-trip through the real RTF format — run boundaries and
        // font identity must survive serialization, not just in-memory.
        let data = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes:
                [.documentType: NSAttributedString.DocumentType.rtf])
        let decoded = try XCTUnwrap(
            NSAttributedString(rtf: data, documentAttributes: nil))

        var runs: [HeadingDetector.FontRun] = []
        decoded.enumerateAttribute(
            NSAttributedString.Key.font,
            in: NSRange(location: 0, length: decoded.length)) {
            value, range, _ in
            guard let font = value as? NSFont else { return }
            runs.append(HeadingDetector.FontRun(range: range,
                                                pointSize: Double(font.pointSize)))
        }
        let headings = HeadingDetector.headings(runs: runs)
        XCTAssertEqual(headings.count, 2)
        XCTAssertEqual(headings.map(\.level), [1, 2],
                       "24pt outranks 18pt over a 12pt body")
        XCTAssertEqual(headings.first?.offset, 0)
        XCTAssertGreaterThan(headings[1].offset, 0)
    }
}
