import XCTest
@testable import marduk

/// The user's own Karabiner rules ride into karabiner.json on the same
/// rewrite that installs Marduk's read button. Two things must hold or
/// this feature damages a config Marduk does not own: a malformed file
/// must degrade to nothing rather than throw, and the merge must be
/// REVERSIBLE — a rule deleted from rules.json has to leave the live
/// config, including from the user's own profile.
final class KarabinerRulesTests: XCTestCase {

    private func rule(_ description: String) -> [String: Any] {
        ["description": description,
         "manipulators": [["type": "basic",
                           "from": ["key_code": "f"],
                           "to": [["shell_command": "open -a FaceTime"]]]]]
    }

    private func data(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func descriptions(_ rules: [[String: Any]]) -> [String] {
        rules.compactMap { $0["description"] as? String }
    }

    // MARK: - Parsing degrades, never throws

    func testParsesObjectFormAndBareArray() {
        let item: [String: Any] = ["rule": rule("FaceTime")]
        XCTAssertEqual(KarabinerRules.parse(data(["rules": [item]])).count, 1)
        XCTAssertEqual(KarabinerRules.parse(data([item])).count, 1)
    }

    func testRuleMayCarryProfilesInline() {
        var inline = rule("FaceTime")
        inline["profiles"] = ["user"]
        let parsed = KarabinerRules.parse(data([inline]))
        XCTAssertEqual(parsed.first?.targets, [.user])
        // Our key must never reach the object Karabiner reads
        XCTAssertNil(parsed.first?.rule["profiles"])
    }

    func testGarbageYieldsNoRules() {
        XCTAssertTrue(KarabinerRules.parse(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(KarabinerRules.parse(data(["rules": "nope"])).isEmpty)
        XCTAssertTrue(KarabinerRules.parse(Data()).isEmpty)
    }

    func testEntriesWithoutADescriptionOrManipulatorsAreDropped() {
        let noDescription: [String: Any] = ["manipulators": [["type": "basic"]]]
        let blankDescription: [String: Any] = ["description": "  ",
                                               "manipulators": [["type": "basic"]]]
        let noManipulators: [String: Any] = ["description": "FaceTime",
                                             "manipulators": []]
        XCTAssertTrue(KarabinerRules.parse(
            data([noDescription, blankDescription, noManipulators])).isEmpty)
    }

    func testOneBadEntryDoesNotCostTheGoodOnes() {
        let parsed = KarabinerRules.parse(
            data([["description": "broken"], rule("FaceTime")]))
        XCTAssertEqual(parsed.map(\.description), ["FaceTime"])
    }

    // MARK: - Targets

    func testMissingOrUnknownProfilesDefaultsToMardukOnly() {
        XCTAssertEqual(KarabinerRules.parse(data([rule("A")])).first?.targets,
                       [.marduk])
        var junk = rule("B")
        junk["profiles"] = ["nonsense", "elsewhere"]
        XCTAssertEqual(KarabinerRules.parse(data([junk])).first?.targets,
                       [.marduk])
    }

    func testProfilesAreCaseAndSpaceInsensitive() {
        var both = rule("C")
        both["profiles"] = [" Marduk ", "USER"]
        XCTAssertEqual(KarabinerRules.parse(data([both])).first?.targets,
                       [.marduk, .user])
    }

    // MARK: - Tagging is what makes removal possible

    func testDescriptionIsTaggedExactlyOnce() {
        let once = KarabinerRules.parse(data([rule("FaceTime")])).first!
        XCTAssertEqual(once.rule["description"] as? String,
                       KarabinerRules.tagPrefix + "FaceTime")
        // Re-importing an already-tagged config must not compound it
        let twice = KarabinerRules.parse(
            data([rule(KarabinerRules.tagPrefix + "FaceTime")])).first!
        XCTAssertEqual(twice.rule["description"] as? String,
                       KarabinerRules.tagPrefix + "FaceTime")
        XCTAssertEqual(twice.description, "FaceTime")
    }

    func testStripRemovesOnlyTaggedRules() {
        let mixed = [rule("Zoom In"),
                     rule(KarabinerRules.tagPrefix + "FaceTime")]
        XCTAssertEqual(descriptions(KarabinerRules.strip(mixed)), ["Zoom In"])
    }

    func testMergeIsIdempotent() {
        let entries = KarabinerRules.parse(data([rule("FaceTime")]))
        let once = KarabinerRules.merge(into: [rule("Zoom In")],
                                        entries: entries, target: .marduk)
        let twice = KarabinerRules.merge(into: once, entries: entries,
                                         target: .marduk)
        XCTAssertEqual(descriptions(once), descriptions(twice))
        XCTAssertEqual(descriptions(twice).count, 2)
    }

    func testMergeDropsRulesNoLongerInTheFile() {
        let entries = KarabinerRules.parse(data([rule("FaceTime")]))
        let applied = KarabinerRules.merge(into: [rule("Zoom In")],
                                           entries: entries, target: .marduk)
        // The user deletes the rule from rules.json — it must leave here too
        let emptied = KarabinerRules.merge(into: applied, entries: [],
                                           target: .marduk)
        XCTAssertEqual(descriptions(emptied), ["Zoom In"])
    }

    func testMergeIgnoresEntriesBoundForTheOtherProfile() {
        var userOnly = rule("FaceTime")
        userOnly["profiles"] = ["user"]
        let entries = KarabinerRules.parse(data([userOnly]))
        XCTAssertTrue(KarabinerRules.merge(into: [], entries: entries,
                                           target: .marduk).isEmpty)
        XCTAssertEqual(KarabinerRules.merge(into: [], entries: entries,
                                            target: .user).count, 1)
    }
}
