import XCTest
import CoreGraphics
@testable import marduk

/// Regressions for bugs found by audit on 2026-07-22 and fixed together.
/// Named by symptom, so a future failure reads as the user experience
/// rather than the mechanism.
final class FieldBugRegressionTests: XCTestCase {

    // MARK: - Headings past the sixth size used to VANISH

    private func run(_ location: Int, _ length: Int, _ size: Double)
        -> HeadingDetector.FontRun {
        HeadingDetector.FontRun(range: NSRange(location: location, length: length),
                                pointSize: size)
    }

    /// Seven distinct heading sizes: the smallest used to fall through
    /// `guard let rank … else { continue }` and disappear from `]]`
    /// navigation entirely — silently, and they are the most numerous.
    func testHeadingsBeyondTheSixthSizeAreStillFound() {
        var runs = [run(0, 500, 12)]   // body — by far the most text
        let sizes: [Double] = [40, 36, 32, 28, 24, 20, 16]
        for (i, size) in sizes.enumerated() {
            runs.append(run(600 + i * 20, 10, size))
        }
        let headings = HeadingDetector.headings(runs: runs)
        XCTAssertEqual(headings.count, sizes.count,
                       "a heading size past the sixth was dropped entirely")
    }

    /// Sizes past the sixth CLAMP to level 6 rather than vanishing, so
    /// they still participate in same-level and parent motions.
    func testExtraSizesClampToTheDeepestLevel() {
        var runs = [run(0, 500, 12)]
        for (i, size) in [40.0, 36, 32, 28, 24, 20, 16].enumerated() {
            runs.append(run(600 + i * 20, 10, size))
        }
        let levels = HeadingDetector.headings(runs: runs).map(\.level)
        XCTAssertEqual(levels, [1, 2, 3, 4, 5, 6, 6])
    }

    /// AX can hand back a non-finite point size. A nan key can never be
    /// looked up again (nan != nan), so such a run would sit in the weight
    /// table unrankable — present but unreachable.
    func testNonFinitePointSizesAreIgnored() {
        let runs = [run(0, 100, 12), run(200, 10, .nan), run(300, 10, 24)]
        let headings = HeadingDetector.headings(runs: runs)
        XCTAssertEqual(headings.map(\.offset), [300],
                       "only the real heading should rank")
    }

    // MARK: - The input cap measured and cut in different units

    /// The cap gates on UTF-16 but used to cut by Character, and a family
    /// emoji is 11 UTF-16 units — so emoji-dense input kept many times the
    /// budget. That budget is the guard against the main-thread stall that
    /// froze the keyboard system-wide, so overshooting it is the bug.
    func testEmojiDenseInputIsCappedInTheUnitsTheGateMeasures() {
        let family = "👨‍👩‍👧‍👦"
        XCTAssertGreaterThan(family.utf16.count, 5, "fixture must be multi-unit")
        let text = String(repeating: family,
                          count: SpeechPreprocessor.maxInputLength)
        let out = SpeechPreprocessor.process(text, settings: .default)
        XCTAssertLessThanOrEqual(
            out.utf16.count, SpeechPreprocessor.maxInputLength,
            "emoji-dense input blew past the cap the keyboard-freeze guard "
            + "depends on")
    }

    /// ASCII must be unaffected — the common path.
    func testPlainTextCapIsUnchanged() {
        let text = String(repeating: "a ", count: SpeechPreprocessor.maxInputLength)
        let out = SpeechPreprocessor.process(text, settings: .default)
        XCTAssertLessThanOrEqual(out.utf16.count, SpeechPreprocessor.maxInputLength)
    }

    /// Cutting must not split a grapheme cluster — a lone surrogate would
    /// be spoken as garbage.
    func testCapNeverSplitsAGraphemeCluster() {
        let text = String(repeating: "👍", count: SpeechPreprocessor.maxInputLength)
        let out = SpeechPreprocessor.process(text, settings: .default)
        XCTAssertFalse(out.isEmpty)
        // A split surrogate pair surfaces as U+FFFD or a stray scalar; every
        // Character here must still be the whole emoji.
        XCTAssertTrue(out.allSatisfy { $0 == "👍" },
                      "the cut landed mid-grapheme and broke a cluster")
        XCTAssertLessThanOrEqual(out.utf16.count, SpeechPreprocessor.maxInputLength)
    }

    // MARK: - Pronunciations depended on macOS's storage order

    private func entry(_ phrase: String, _ replacement: String) -> SystemPronunciations.Entry {
        SystemPronunciations.Entry(phrase: phrase, replacement: replacement,
                                   ipa: nil, active: true, ignoreCase: true,
                                   language: nil, appliesToAllApps: true,
                                   bundleIdentifiers: [])
    }

    /// A chain (A→B, B→C) used to resolve differently depending on the
    /// order the entries happened to be stored in — the same dictionary
    /// could read a document two different ways.
    func testChainedSubstitutionsDoNotDependOnEntryOrder() {
        let a = entry("marduk", "banana")
        let b = entry("banana", "fruit")
        let forward = SystemPronunciations.applyText([a, b], to: "marduk here")
        let reverse = SystemPronunciations.applyText([b, a], to: "marduk here")
        XCTAssertEqual(forward, reverse,
                       "entry order changed how the document reads")
        XCTAssertEqual(forward, "banana here",
                       "each entry matches the ORIGINAL text, so no chaining")
    }

    /// Independent entries still all apply.
    func testIndependentEntriesAllApply() {
        let out = SystemPronunciations.applyText(
            [entry("cat", "feline"), entry("dog", "canine")], to: "cat and dog")
        XCTAssertEqual(out, "feline and canine")
    }

    /// Overlaps resolve longest-phrase-first — deterministic whatever
    /// order the store hands them over in.
    func testOverlappingPhrasesResolveLongestFirst() {
        let short = entry("new", "fresh")
        let long = entry("new york", "the big apple")
        let forward = SystemPronunciations.applyText([short, long], to: "new york")
        let reverse = SystemPronunciations.applyText([long, short], to: "new york")
        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward, "the big apple")
    }

    // MARK: - meanBrightness across real capture formats

    private func image(bytes: [UInt8], width: Int, height: Int,
                       bytesPerPixel: Int, bytesPerRow: Int,
                       alphaInfo: CGImageAlphaInfo) -> CGImage? {
        let data = CFDataCreate(nil, bytes, bytes.count)!
        let provider = CGDataProvider(data: data)!
        return CGImage(width: width, height: height, bitsPerComponent: 8,
                       bitsPerPixel: bytesPerPixel * 8, bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: alphaInfo.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// The dangerous case: an opaque ARGB capture. Reading from offset 0
    /// would sum alpha(255)+R+G instead of R+G+B, inflating a DARK app's
    /// brightness by up to a third — and inverting a screen that was fine.
    func testAlphaFirstCaptureDoesNotCountAlphaAsColor() throws {
        // Opaque black: alpha 255, colors 0. Naive reading gives ~0.33.
        let pixels = [UInt8](repeating: 0, count: 4 * 4 * 4).enumerated().map {
            $0.offset % 4 == 0 ? UInt8(255) : UInt8(0)
        }
        let img = try XCTUnwrap(image(bytes: pixels, width: 4, height: 4,
                                      bytesPerPixel: 4, bytesPerRow: 16,
                                      alphaInfo: .premultipliedFirst))
        let brightness = try XCTUnwrap(DisplayInverter.meanBrightness(img))
        XCTAssertLessThan(brightness, 0.05,
                          "an opaque BLACK ARGB capture read as bright — this "
                          + "is how a dark app gets inverted")
    }

    /// Rows are commonly padded; the loop must honour bytesPerRow rather
    /// than assuming width * bytesPerPixel.
    func testRowPaddingIsHonoured() throws {
        let width = 3, height = 2, bpp = 4
        let bytesPerRow = width * bpp + 8   // padded
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = y * bytesPerRow + x * bpp
                bytes[p] = 255; bytes[p + 1] = 255; bytes[p + 2] = 255
            }
        }
        // Padding bytes stay 0 — if they were sampled, the mean would drop
        let img = try XCTUnwrap(image(bytes: bytes, width: width, height: height,
                                      bytesPerPixel: bpp, bytesPerRow: bytesPerRow,
                                      alphaInfo: .noneSkipLast))
        let brightness = try XCTUnwrap(DisplayInverter.meanBrightness(img))
        XCTAssertEqual(brightness, 1.0, accuracy: 0.01,
                       "padding bytes were sampled as image data")
    }
}
