import XCTest
@testable import marduk

final class SpeechPreprocessorTests: XCTestCase {

    private let most = SpeechPreprocessor.Settings.default
    private let all = SpeechPreprocessor.Settings(verbosity: .all, overrides: [:])
    private let some = SpeechPreprocessor.Settings(verbosity: .some, overrides: [:])
    private let none = SpeechPreprocessor.Settings(verbosity: .none, overrides: [:])

    // MARK: - Sanitize (anti-bail)

    func testStripsControlCharacters() {
        XCTAssertEqual(SpeechPreprocessor.sanitize("a\u{01}b\u{07}c\u{1B}d"), "abcd")
    }

    func testKeepsNewlineAndTab() {
        XCTAssertEqual(SpeechPreprocessor.sanitize("a\nb\tc"), "a\nb\tc")
    }

    func testNormalizesLineEndings() {
        XCTAssertEqual(SpeechPreprocessor.sanitize("a\r\nb\rc\u{2028}d\u{2029}e"), "a\nb\nc\nd\ne")
    }

    func testStripsInvisibleFormatCharacters() {
        // ZWSP, BOM, soft hyphen, RLO, LRM
        XCTAssertEqual(SpeechPreprocessor.sanitize("a\u{200B}b\u{FEFF}c\u{00AD}d\u{202E}e\u{200E}f"), "abcdef")
    }

    func testStripsVariationSelectorsAndReplacementChars() {
        XCTAssertEqual(SpeechPreprocessor.sanitize("a\u{FE0F}b\u{FFFD}c\u{FFFC}d"), "abcd")
    }

    func testStripsPrivateUse() {
        XCTAssertEqual(SpeechPreprocessor.sanitize("a\u{F8FF}b"), "ab")
    }

    func testSpaceSeparatorsBecomeSpace() {
        // NBSP, thin space
        XCTAssertEqual(SpeechPreprocessor.sanitize("a\u{00A0}b\u{2009}c"), "a b c")
    }

    func testKeepsEmojiZWJSequence() {
        let family = "👨\u{200D}👩\u{200D}👧"
        XCTAssertEqual(SpeechPreprocessor.sanitize(family), family)
    }

    func testStripsTextZWJ() {
        XCTAssertEqual(SpeechPreprocessor.sanitize("a\u{200D}b"), "ab")
    }

    func testKeepsCombiningMarks() {
        XCTAssertEqual(SpeechPreprocessor.sanitize("cafe\u{0301}"), "cafe\u{0301}")
    }

    // MARK: - Verbalize levels

    func testMostSpeaksCodeSymbols() {
        XCTAssertEqual(SpeechPreprocessor.process("foo_bar", settings: most), "foo underscore bar")
        XCTAssertEqual(SpeechPreprocessor.process("{x}", settings: most), "open brace x close brace")
        XCTAssertEqual(SpeechPreprocessor.process("`code`", settings: most), "backtick code backtick")
    }

    func testMostLeavesProsePunctuation() {
        XCTAssertEqual(SpeechPreprocessor.process("Hello, world!", settings: most), "Hello, world!")
    }

    func testAllSpeaksProsePunctuation() {
        XCTAssertEqual(SpeechPreprocessor.process("a.", settings: all), "a dot")
        XCTAssertEqual(SpeechPreprocessor.process("(x)", settings: all), "open paren x close paren")
    }

    func testSomeSpeaksOnlyDroppedSymbols() {
        XCTAssertEqual(SpeechPreprocessor.process("{x}", settings: some), "open brace x close brace")
        XCTAssertEqual(SpeechPreprocessor.process("a=b", settings: some), "a=b")
    }

    func testNoneLeavesSymbolsRaw() {
        XCTAssertEqual(SpeechPreprocessor.process("a{b}c", settings: none), "a{b}c")
    }

    // MARK: - Digraphs and runs

    func testDigraphs() {
        XCTAssertEqual(SpeechPreprocessor.process("a->b", settings: most), "a arrow b")
        XCTAssertEqual(SpeechPreprocessor.process("a != b", settings: most), "a not equals b")
        XCTAssertEqual(SpeechPreprocessor.process("a == b", settings: most), "a double equals b")
        XCTAssertEqual(SpeechPreprocessor.process("Foo::bar", settings: most), "Foo double colon bar")
    }

    func testRunCollapseBeatsDigraph() {
        XCTAssertEqual(SpeechPreprocessor.process("====", settings: most), "4 equals")
        XCTAssertEqual(SpeechPreprocessor.process("=====", settings: most), "5 equals")
    }

    func testRunNamingFallsBackToFullTable() {
        // '-', '!', '/' aren't spoken singly at most, but their runs are named
        XCTAssertEqual(SpeechPreprocessor.process("-----", settings: most), "5 dash")
        XCTAssertEqual(SpeechPreprocessor.process("wow!!!!!!", settings: most), "wow 6 exclamation")
        XCTAssertEqual(SpeechPreprocessor.process("/// doc", settings: most), "3 slash doc")
        XCTAssertEqual(SpeechPreprocessor.process("+++", settings: most), "3 plus")
    }

    func testBareEllipsisStaysNatural() {
        // Exactly three dots is prose — natural pause, not "3 dot"
        XCTAssertEqual(SpeechPreprocessor.process("wait... what", settings: most), "wait... what")
        XCTAssertEqual(SpeechPreprocessor.process(".....", settings: most), "5 dot")
        // .all speaks all punctuation, ellipsis included
        XCTAssertEqual(SpeechPreprocessor.process("wait... what", settings: all), "wait 3 dot what")
    }

    func testUnnamedSymbolRunIsCapped() {
        // '€' has no table name; runs cap at 3 — pathological-run defense
        XCTAssertEqual(SpeechPreprocessor.process("a€€€€€b", settings: most), "a€€€b")
        // Cap applies at .none too — the anti-bail path with no verbalization
        XCTAssertEqual(SpeechPreprocessor.process("a??????b", settings: none), "a???b")
    }

    func testLetterAndDigitRunsNeverCollapse() {
        XCTAssertEqual(SpeechPreprocessor.process("aaaa 1111", settings: most), "aaaa 1111")
    }

    // MARK: - Overrides

    func testOverrideRenamesSymbol() {
        let s = SpeechPreprocessor.Settings(verbosity: .most, overrides: ["*": "asterisk"])
        XCTAssertEqual(SpeechPreprocessor.process("a*b", settings: s), "a asterisk b")
    }

    func testOverrideRenamesDigraph() {
        let s = SpeechPreprocessor.Settings(verbosity: .most, overrides: ["->": "maps to"])
        XCTAssertEqual(SpeechPreprocessor.process("a->b", settings: s), "a maps to b")
    }

    func testOverrideAddsNewSymbol() {
        let s = SpeechPreprocessor.Settings(verbosity: .most, overrides: ["🚀": "rocket"])
        XCTAssertEqual(SpeechPreprocessor.process("go 🚀 now", settings: s), "go rocket now")
    }

    func testOverrideSilencesSymbol() {
        let s = SpeechPreprocessor.Settings(verbosity: .most, overrides: ["%": ""])
        XCTAssertEqual(SpeechPreprocessor.process("50% off", settings: s), "50 off")
    }

    func testOverridesInactiveAtNone() {
        let s = SpeechPreprocessor.Settings(verbosity: .none, overrides: ["*": "asterisk"])
        XCTAssertEqual(SpeechPreprocessor.process("a*b", settings: s), "a*b")
    }

    // MARK: - Hash abbreviation

    private let md5 = "d41d8cd98f00b204e9800998ecf8427e"                     // 32
    private let sha1 = "da39a3ee5e6b4b0d3255bfef95601890afd80709"            // 40
    private let sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"  // 64

    func testAbbreviatesMD5() {
        XCTAssertEqual(SpeechPreprocessor.process(md5, settings: most), "md5 ending in 2 7 e")
    }

    func testAbbreviatesSHA1AndSHA256() {
        XCTAssertEqual(SpeechPreprocessor.process(sha1, settings: most), "sha1 ending in 7 0 9")
        XCTAssertEqual(SpeechPreprocessor.process(sha256, settings: most), "sha256 ending in 8 5 5")
    }

    func testAbbreviatesSHA512() {
        let sha512 = String(repeating: "ab12", count: 32)  // 128 hex chars
        XCTAssertEqual(SpeechPreprocessor.process(sha512, settings: most), "sha512 ending in b 1 2")
    }

    func testAbbreviatesHashInContext() {
        XCTAssertEqual(
            SpeechPreprocessor.process("commit \(sha1) pushed", settings: most),
            "commit sha1 ending in 7 0 9 pushed")
    }

    func testAbbreviatesUppercaseHash() {
        XCTAssertEqual(
            SpeechPreprocessor.process(md5.uppercased(), settings: most),
            "md5 ending in 2 7 E")
    }

    func testHashRunsAtNoneLevelToo() {
        XCTAssertEqual(SpeechPreprocessor.process(md5, settings: none), "md5 ending in 2 7 e")
    }

    func testNonStandardLengthNotAbbreviated() {
        let hex31 = String(md5.dropLast())
        let hex33 = md5 + "a"
        XCTAssertEqual(SpeechPreprocessor.process(hex31, settings: most), hex31)
        XCTAssertEqual(SpeechPreprocessor.process(hex33, settings: most), hex33)
    }

    func testNonHexAndEmbeddedRunsNotAbbreviated() {
        let withG = "g" + md5.dropFirst()             // 32 chars but not hex
        let embedded = "x" + md5                      // hash inside a longer word
        XCTAssertEqual(SpeechPreprocessor.process(withG, settings: most), withG)
        XCTAssertEqual(SpeechPreprocessor.process(embedded, settings: most), embedded)
    }

    func testAllDigitOrAllLetterRunsNotAbbreviated() {
        let digits32 = String(repeating: "12345678", count: 4)
        let letters32 = String(repeating: "deadbeef", count: 4)
        XCTAssertEqual(SpeechPreprocessor.process(digits32, settings: most), digits32)
        XCTAssertEqual(SpeechPreprocessor.process(letters32, settings: most), letters32)
    }

    func testHashAbbreviationDisabled() {
        let s = SpeechPreprocessor.Settings(verbosity: .most, overrides: [:], hashes: false)
        XCTAssertEqual(SpeechPreprocessor.process(md5, settings: s), md5)
    }

    func testSettingsReadHashFlagFromConfig() {
        var block = MardukConfig.VerbalizerConfig()
        block.hashes = false
        XCTAssertFalse(SpeechPreprocessor.settings(from: block).hashes)
        XCTAssertTrue(SpeechPreprocessor.settings(from: nil).hashes)
    }

    // MARK: - Whitespace

    func testCollapsesSpaceRuns() {
        XCTAssertEqual(SpeechPreprocessor.process("a   b\t\tc", settings: most), "a b c")
    }

    func testCollapsesBlankLines() {
        XCTAssertEqual(SpeechPreprocessor.process("a\n\n  \nb", settings: most), "a\nb")
    }

    func testTrimsEnds() {
        XCTAssertEqual(SpeechPreprocessor.process("  a  ", settings: most), "a")
    }

    // MARK: - Empty and pathological input

    func testInvisibleOnlyInputBecomesEmpty() {
        XCTAssertEqual(SpeechPreprocessor.process("\u{200B}\u{FEFF}", settings: most), "")
        XCTAssertEqual(SpeechPreprocessor.process("\u{01}\u{02}", settings: most), "")
    }

    func testWhitespaceOnlyInputBecomesEmpty() {
        XCTAssertEqual(SpeechPreprocessor.process("   \n\t ", settings: most), "")
    }

    // MARK: - Config factory

    func testSettingsFromNilBlockDefaultsToMost() {
        let s = SpeechPreprocessor.settings(from: nil)
        XCTAssertEqual(s.verbosity, .most)
    }

    func testSettingsFromUnknownLevelFallsBackToMost() {
        var block = MardukConfig.VerbalizerConfig()
        block.level = "bogus"
        let s = SpeechPreprocessor.settings(from: block)
        XCTAssertEqual(s.verbosity, .most)
    }

    func testSettingsParsesLevelCaseInsensitively() {
        var block = MardukConfig.VerbalizerConfig()
        block.level = "ALL"
        let s = SpeechPreprocessor.settings(from: block)
        XCTAssertEqual(s.verbosity, .all)
    }

    func testPartialConfigDecodeSurvivesMissingVerbalizerKey() throws {
        // Regression guard: a config.json without the verbalizer key must
        // still decode (ConfigLoader resets the file on decode failure).
        let json = #"{"ducking":{"duckLevel":5,"rampSteps":15,"rampDurationMs":600,"duckAppleMusic":true,"duckSpotify":true,"useMediaKey":true},"speech":{"rate":0.59},"display":{"invertForApps":[]}}"#
        let config = try JSONDecoder().decode(MardukConfig.self, from: Data(json.utf8))
        XCTAssertNil(config.verbalizer)
        XCTAssertEqual(SpeechPreprocessor.settings(from: config.verbalizer).verbosity, .most)
        XCTAssertTrue(SpeechPreprocessor.settings(from: config.verbalizer).identifiers)
    }

    // MARK: - Identifier splitting

    private func split(_ text: String) -> String {
        SpeechPreprocessor.splitIdentifiers(text)
    }

    func testCamelCaseSplits() {
        XCTAssertEqual(split("readDocumentFromCaret"), "read Document From Caret")
        XCTAssertEqual(split("fooBar and bazQux"), "foo Bar and baz Qux")
        XCTAssertEqual(split("iPhone"), "i Phone")
    }

    func testAcronymBoundarySplitsBeforeFollowingWord() {
        XCTAssertEqual(split("XMLHttpRequest"), "XML Http Request")
        XCTAssertEqual(split("parseHTMLBody"), "parse HTML Body")
    }

    func testSnakeCaseSplits() {
        XCTAssertEqual(split("user_id_count"), "user id count")
        XCTAssertEqual(split("MAX_RETRY_COUNT"), "MAX RETRY COUNT")
    }

    func testDigitTransitionsSplitInsideIdentifiers() {
        XCTAssertEqual(split("utf16Offset"), "utf 16 Offset")
        XCTAssertEqual(split("parseHTMLBody_v2"), "parse HTML Body v 2")
    }

    func testNonIdentifiersUntouched() {
        XCTAssertEqual(split("Hello there, plain words."), "Hello there, plain words.")
        XCTAssertEqual(split("APT"), "APT")          // ALLCAPS acronym
        XCTAssertEqual(split("UTF16"), "UTF16")      // acronym + digits, no lowercase
        XCTAssertEqual(split("sha256"), "sha256")    // no hump, no snake
        XCTAssertEqual(split("Page2"), "Page2")      // capitalized word + digit
    }

    func testEdgeUnderscoresLeftForSymbolStage() {
        XCTAssertEqual(split("__init__"), "__init__")
        XCTAssertEqual(split("_privateVar"), "_private Var")
        XCTAssertEqual(split("a__b"), "a__b")        // doubled = not internal
    }

    func testIdentifiersToggleOffPassesThrough() {
        let settings = SpeechPreprocessor.Settings(verbosity: .most, overrides: [:],
                                                   identifiers: false)
        let out = SpeechPreprocessor.process("readDocumentFromCaret user_id", settings: settings)
        XCTAssertTrue(out.contains("readDocumentFromCaret"))
        XCTAssertTrue(out.contains("user underscore id"))
    }

    func testIdentifierSplitRunsInFullPipeline() {
        let out = SpeechPreprocessor.process("call readDocumentFromCaret on user_id_count",
                                             settings: .default)
        XCTAssertEqual(out, "call read Document From Caret on user id count")
    }

    func testHashAbbreviationWinsOverSplitting() {
        // A digest is collapsed by the hash stage before the splitter runs —
        // mixed-case hex like DeadBeef… must not come out camel-split
        let digest = String(repeating: "D3adBeef", count: 4)  // 32 hex chars
        let out = SpeechPreprocessor.process(digest, settings: .default)
        XCTAssertTrue(out.hasPrefix("md5 ending in"), out)
    }
}
