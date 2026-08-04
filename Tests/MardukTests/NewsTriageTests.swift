import XCTest
@testable import marduk

/// The triage core is pure and the model is a 4B local LLM — the parser
/// must survive everything it emits, and the prompt/spoken forms are
/// what the user actually hears.
final class NewsTriageTests: XCTestCase {

    private let items: [NewsTriage.Item] = [
        .init(id: 11, feedTitle: "Krebs on Security", title: "Citrix zero day exploited"),
        .init(id: 22, feedTitle: "The Hacker News", title: "Citrix 0-day under attack"),
        .init(id: 33, feedTitle: "CISA Alerts", title: "Emergency directive on Citrix"),
        .init(id: 44, feedTitle: "Troy Hunt", title: "Weekly update 412"),
        .init(id: 55, feedTitle: "BleepingComputer", title: "New ransomware crew emerges"),
    ]

    func testPromptNumbersEveryHeadlineWithItsSource() {
        let prompt = NewsTriage.prompt(items: items)
        XCTAssertTrue(prompt.contains("1. [Krebs on Security] Citrix zero day exploited"))
        XCTAssertTrue(prompt.contains("5. [BleepingComputer] New ransomware crew emerges"))
        XCTAssertTrue(prompt.contains("STRICT JSON"))
    }

    func testParseHappyPath() {
        let response = """
            {"top":[{"n":3,"why":"federal emergency directive"},
                    {"n":5,"why":"new threat actor"},
                    {"n":1,"why":"active exploitation"}],
             "dupes":[[1,2,3]]}
            """
        guard let result = NewsTriage.parse(response: response, items: items) else {
            return XCTFail("happy path failed to parse")
        }
        XCTAssertEqual(result.top.map(\.item.id), [33, 55, 11])
        XCTAssertEqual(result.top.first?.why, "federal emergency directive")
        XCTAssertEqual(result.duplicatesCollapsed, 2)
    }

    func testParseSurvivesFencesProseAndBadNumbers() {
        let response = """
            Here you go!
            ```json
            {"top":[{"n":99,"why":"out of range"},{"n":2,"why":"ok"},
                    {"n":2,"why":"repeat"},{"n":0,"why":"zero"}],
             "dupes":[[1,99],[4]]}
            ```
            """
        guard let result = NewsTriage.parse(response: response, items: items) else {
            return XCTFail("defensive parse failed")
        }
        // Only the one valid, non-duplicate pick survives
        XCTAssertEqual(result.top.map(\.item.id), [22])
        // A dupe group needs 2+ VALID members to collapse anything
        XCTAssertEqual(result.duplicatesCollapsed, 0)
    }

    func testParseGarbageIsNilNeverACrash() {
        XCTAssertNil(NewsTriage.parse(response: "no json here", items: items))
        XCTAssertNil(NewsTriage.parse(response: "{}", items: items))
        XCTAssertNil(NewsTriage.parse(response: "{\"top\":[]}", items: items))
        XCTAssertNil(NewsTriage.parse(response: "", items: []))
    }

    func testSpokenSummaryShape() {
        let result = NewsTriage.Result(
            top: [.init(item: items[2], why: "federal directive"),
                  .init(item: items[4], why: "")],
            duplicatesCollapsed: 3)
        let spoken = NewsTriage.spoken(result)
        XCTAssertTrue(spoken.hasPrefix("Top 2."))
        XCTAssertTrue(spoken.contains(
            "One: Emergency directive on Citrix, from CISA Alerts. federal directive."))
        XCTAssertTrue(spoken.contains("Two: New ransomware crew emerges"))
        XCTAssertTrue(spoken.contains("3 duplicates collapsed."))
        XCTAssertTrue(spoken.hasSuffix("Press 1, 2 to read."))
        // No dupes = no dupe clause
        let clean = NewsTriage.Result(top: [.init(item: items[0], why: "x")],
                                      duplicatesCollapsed: 0)
        XCTAssertFalse(NewsTriage.spoken(clean).contains("duplicates"))
        XCTAssertTrue(NewsTriage.spoken(clean).hasSuffix("Press 1 to read."))
    }

    func testPickModelPrefersConfiguredThenGemma3ThenGemmFamily() {
        // The user's real inventory: gemma4:e4b listed FIRST, but the
        // fast gemma3:4b must win the auto-pick (speed ruling)
        let inventory = ["gemma4:e4b", "llama3:latest", "llama3.1:8b",
                         "gemma3:4b"]
        XCTAssertEqual(NewsTriage.pickModel(configured: nil,
                                            available: inventory), "gemma3:4b")
        // Pinning gemma4 in config wins over the speed default
        XCTAssertEqual(NewsTriage.pickModel(configured: "gemma4:e4b",
                                            available: inventory), "gemma4:e4b")
        // A configured prefix resolves to its full tag
        XCTAssertEqual(NewsTriage.pickModel(configured: "gemma4",
                                            available: inventory), "gemma4:e4b")
        // No gemma3: any gemm-family tag beats non-gemm list order
        XCTAssertEqual(NewsTriage.pickModel(
            configured: nil,
            available: ["llama3.2:3b", "gemm4-instruct:latest"]),
            "gemm4-instruct:latest")
        // No gemm anywhere: first model; nothing at all: nil
        XCTAssertEqual(NewsTriage.pickModel(configured: nil,
                                            available: ["llama3.2:3b"]),
                       "llama3.2:3b")
        XCTAssertNil(NewsTriage.pickModel(configured: nil, available: []))
        // A configured tag Ollama doesn't list is still trusted (Ollama
        // will error honestly if it's truly absent)
        XCTAssertEqual(NewsTriage.pickModel(configured: "brandnew:1b",
                                            available: inventory), "brandnew:1b")
    }
}
