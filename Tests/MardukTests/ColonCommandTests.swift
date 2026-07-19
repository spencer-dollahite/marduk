import XCTest
@testable import marduk

final class ColonCommandTests: XCTestCase {

    // MARK: - Parser

    func testParsesCommandsAndAliases() {
        XCTAssertEqual(ColonCommand.parse("help"), .help)
        XCTAssertEqual(ColonCommand.parse("h"), .help)
        XCTAssertEqual(ColonCommand.parse("commands"), .commands)
        XCTAssertEqual(ColonCommand.parse("c"), .commands)
        XCTAssertEqual(ColonCommand.parse("tutorial"), .tutorial)
    }

    func testParseIsCaseInsensitiveAndSpaceTolerant() {
        XCTAssertEqual(ColonCommand.parse("HELP"), .help)
        XCTAssertEqual(ColonCommand.parse("  config   rate   200  "),
                       .config(key: "rate", value: "200"))
    }

    func testParsesConfigAndSetAlias() {
        XCTAssertEqual(ColonCommand.parse("config rate 200"),
                       .config(key: "rate", value: "200"))
        XCTAssertEqual(ColonCommand.parse("set level all"),
                       .config(key: "level", value: "all"))
    }

    func testConfigArityMismatchIsUnknown() {
        XCTAssertEqual(ColonCommand.parse("config rate"), .unknown("config rate"))
        XCTAssertEqual(ColonCommand.parse("config"), .unknown("config"))
        XCTAssertEqual(ColonCommand.parse("config rate 200 extra"),
                       .unknown("config rate 200 extra"))
    }

    func testUnknownCommand() {
        XCTAssertEqual(ColonCommand.parse("bogus"), .unknown("bogus"))
        XCTAssertEqual(ColonCommand.parse(""), .unknown(""))
    }

    // MARK: - Unique-prefix expansion

    func testUniquePrefixExpandsCommands() {
        XCTAssertEqual(ColonCommand.parse("tut"), .tutorial)
        XCTAssertEqual(ColonCommand.parse("ti"), .tip)
        XCTAssertEqual(ColonCommand.parse("he"), .help)
        XCTAssertEqual(ColonCommand.parse("conf ra 230"),
                       .config(key: "rate", value: "230"))
    }

    func testAmbiguousPrefixIsUnknown() {
        // "co" matches both commands and config; "t" both tutorial and tip
        XCTAssertEqual(ColonCommand.parse("co"), .unknown("co"))
        XCTAssertEqual(ColonCommand.parse("t"), .unknown("t"))
    }

    func testPrefixExpandsKeysAndEnumValues() {
        XCTAssertEqual(ColonCommand.parse("config le m"),
                       .config(key: "level", value: "most"))
        XCTAssertEqual(ColonCommand.parse("config res of"),
                       .config(key: "rescue", value: "off"))
    }

    func testAmbiguousKeyOrValuePassesThroughRaw() {
        // "e" matches escapehold and echo — left raw for the executor's error
        XCTAssertEqual(ColonCommand.parse("config e on"),
                       .config(key: "e", value: "on"))
        // "o" matches on and off
        XCTAssertEqual(ColonCommand.parse("config rescue o"),
                       .config(key: "rescue", value: "o"))
    }

    func testExpandHelper() {
        XCTAssertEqual(ColonCommand.expand("tu", in: ColonCommand.commandNames), "tutorial")
        XCTAssertEqual(ColonCommand.expand("help", in: ColonCommand.commandNames), "help")
        XCTAssertNil(ColonCommand.expand("c", in: ColonCommand.commandNames))
        XCTAssertNil(ColonCommand.expand("", in: ColonCommand.commandNames))
        XCTAssertNil(ColonCommand.expand("zzz", in: ColonCommand.commandNames))
    }

    // MARK: - Completer

    private func completions(_ buffer: String,
                             values: [String: String] = [:]) -> [String] {
        CommandCompleter.candidates(for: buffer, values: values).map(\.display)
    }

    func testEmptyBufferListsAllCommands() {
        XCTAssertEqual(completions(""), ["help", "commands", "tutorial", "tip", "config"])
    }

    func testPartialCommandFilters() {
        XCTAssertEqual(completions("c"), ["commands", "config"])
        XCTAssertEqual(completions("tu"), ["tutorial"])
        XCTAssertEqual(completions("t"), ["tutorial", "tip"])
        XCTAssertEqual(completions("z"), [])
    }

    func testConfigCompletionAddsTrailingSpace() {
        let candidates = CommandCompleter.candidates(for: "conf", values: [:])
        XCTAssertEqual(candidates.first?.completion, "config ")
    }

    func testConfigStageListsKeysWithCurrentValues() {
        let displays = completions("config ", values: ["rate": "200"])
        XCTAssertTrue(displays.contains("rate — 200"))
        XCTAssertTrue(displays.contains("level"))
        XCTAssertEqual(displays.count, ColonCommand.settings.count)
    }

    func testConfigKeyPrefixFilters() {
        XCTAssertEqual(completions("config e"), ["escapehold", "echo"])
        XCTAssertEqual(completions("set r", values: ["rate": "180"]),
                       ["rate — 180", "rescue"])
    }

    func testToggleValueStage() {
        XCTAssertEqual(completions("config rescue "), ["on", "off"])
        XCTAssertEqual(completions("config rescue o"), ["on", "off"])
        XCTAssertEqual(completions("config rescue on"), ["on"])
        let candidate = CommandCompleter.candidates(for: "config rescue of", values: [:]).first
        XCTAssertEqual(candidate?.completion, "config rescue off")
    }

    func testChoiceValueStage() {
        XCTAssertEqual(completions("config level "), ["none", "some", "most", "all"])
        XCTAssertEqual(completions("config level m"), ["most"])
    }

    func testNumberValueStageIsHintOnly() {
        let candidates = CommandCompleter.candidates(for: "config rate ", values: [:])
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.display, "50 to 360 words per minute")
        XCTAssertNil(candidates.first?.completion)
    }

    func testCompleteCommandsHaveNoFurtherCandidates() {
        XCTAssertEqual(completions("help "), [])
        XCTAssertEqual(completions("tutorial extra"), [])
        XCTAssertEqual(completions("config bogus "), [])
    }
}
