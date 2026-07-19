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
        // "co" matches commands/config; "t" tutorial/tip; "u" update/uninstall
        XCTAssertEqual(ColonCommand.parse("co"), .unknown("co"))
        XCTAssertEqual(ColonCommand.parse("t"), .unknown("t"))
        XCTAssertEqual(ColonCommand.parse("u"), .unknown("u"))
    }

    func testParsesDaemonCommands() {
        XCTAssertEqual(ColonCommand.parse("quit"), .quit)
        XCTAssertEqual(ColonCommand.parse("q"), .quit)
        XCTAssertEqual(ColonCommand.parse("restart"), .restart)
        XCTAssertEqual(ColonCommand.parse("up"), .update)
        XCTAssertEqual(ColonCommand.parse("un"), .uninstall)
        XCTAssertEqual(ColonCommand.parse("log"), .log)
        XCTAssertEqual(ColonCommand.parse("f"), .feedback)
        XCTAssertEqual(ColonCommand.parse("b"), .bug)
        XCTAssertEqual(ColonCommand.autoResolve("q"), .execute("quit"))
    }

    func testLogCopy() {
        XCTAssertEqual(ColonCommand.parse("log copy"), .logCopy)
        XCTAssertEqual(ColonCommand.parse("log c"), .logCopy)
        XCTAssertEqual(ColonCommand.parse("log bogus"), .unknown("log bogus"))
        XCTAssertEqual(ColonCommand.autoResolve("log c"), .execute("log copy"))
        XCTAssertEqual(completions("log "),
                       ["copy — copy recent log lines to the clipboard"])
        XCTAssertEqual(completions("log x"), [])
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

    // MARK: - Auto-accept

    func testAutoResolveExecutesArglessCommandsWhenUnique() {
        XCTAssertEqual(ColonCommand.autoResolve("h"), .execute("help"))
        XCTAssertEqual(ColonCommand.autoResolve("tu"), .execute("tutorial"))
        XCTAssertEqual(ColonCommand.autoResolve("help"), .execute("help"))
    }

    func testAutoResolveExpandsConfigStages() {
        XCTAssertEqual(ColonCommand.autoResolve("con"), .expand("config "))
        XCTAssertEqual(ColonCommand.autoResolve("config"), .expand("config "))
        XCTAssertEqual(ColonCommand.autoResolve("config ra"), .expand("config rate "))
        XCTAssertEqual(ColonCommand.autoResolve("set ra"), .expand("set rate "))
    }

    func testAutoResolveExecutesUniqueEnumValues() {
        XCTAssertEqual(ColonCommand.autoResolve("config rescue on"),
                       .execute("config rescue on"))
        XCTAssertEqual(ColonCommand.autoResolve("config level m"),
                       .execute("config level most"))
    }

    func testAutoResolveStaysQuietWhenAmbiguousOrOpenEnded() {
        XCTAssertEqual(ColonCommand.autoResolve("t"), .none)          // tutorial|tip
        XCTAssertEqual(ColonCommand.autoResolve("config r"), .none)   // rate|rescue
        XCTAssertEqual(ColonCommand.autoResolve("config rescue o"), .none) // on|off
        XCTAssertEqual(ColonCommand.autoResolve("config rate 230"), .none) // number: Enter
        XCTAssertEqual(ColonCommand.autoResolve("config "), .none)    // trailing space
        XCTAssertEqual(ColonCommand.autoResolve(""), .none)
    }

    // MARK: - Fuzzy search

    func testFuzzyScoreBasics() {
        XCTAssertNotNil(ColonCommand.fuzzyScore(query: "rat", target: "config rate "))
        XCTAssertNotNil(ColonCommand.fuzzyScore(query: "cfgr", target: "config rate "))
        XCTAssertNil(ColonCommand.fuzzyScore(query: "xyz", target: "config rate "))
        // Tighter match scores lower
        let exact = ColonCommand.fuzzyScore(query: "log", target: "log")!
        let spread = ColonCommand.fuzzyScore(query: "log", target: "level orange gap")!
        XCTAssertLessThan(exact, spread)
    }

    func testSlashSearchesWholeCatalog() {
        let all = completions("/", values: ["rate": "200 wpm"])
        XCTAssertEqual(all.count,
                       ColonCommand.commandNames.count + ColonCommand.settings.count)
        let rate = completions("/rate", values: ["rate": "200 wpm"])
        XCTAssertTrue(rate.contains("config rate — 200 wpm"))
        XCTAssertFalse(rate.contains("quit — stop Marduk"))
    }

    func testSlashBufferNeverAutoResolves() {
        XCTAssertEqual(ColonCommand.autoResolve("/h"), .none)
        XCTAssertEqual(ColonCommand.autoResolve("/quit"), .none)
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

    private let commandDisplays = [
        "help — speak the basics",
        "commands — the full key reference",
        "tutorial — interactive guided tour",
        "tip — a random feature tip",
        "config — change a setting",
        "quit — stop Marduk",
        "restart — restart the daemon",
        "update — install updates now",
        "uninstall — remove the launch agent",
        "log — open the log file",
        "feedback — open GitHub issues",
        "bug — report a bug on GitHub",
    ]

    func testEmptyBufferListsAllCommands() {
        XCTAssertEqual(completions(""), commandDisplays)
    }

    func testPartialCommandFilters() {
        XCTAssertEqual(completions("c"), [commandDisplays[1], commandDisplays[4]])
        XCTAssertEqual(completions("tu"), [commandDisplays[2]])
        XCTAssertEqual(completions("t"), [commandDisplays[2], commandDisplays[3]])
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
