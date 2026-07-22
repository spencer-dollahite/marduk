import XCTest
@testable import marduk

final class ReleaseCheckTests: XCTestCase {

    func testParsesTagAndStripsV() {
        XCTAssertEqual(ReleaseCheck.parseLatestTag(#"{"tag_name": "v0.3.2"}"#), "0.3.2")
        XCTAssertEqual(ReleaseCheck.parseLatestTag(#"{"tag_name": "1.0.0"}"#), "1.0.0")
    }

    func testRealPayloadShape() {
        let json = #"{"url": "https://api.github.com/x", "tag_name": "v0.4.0", "assets": [{"name": "Marduk.dmg"}], "prerelease": false}"#
        XCTAssertEqual(ReleaseCheck.parseLatestTag(json), "0.4.0")
    }

    func testParsesReleaseNotesAndStopsAtFooter() {
        // Shape release.sh actually publishes: subject bullets, blank
        // line, --- rule, install footer
        let body = "- Fix the thing\n- Add the feature\n\n---\n**Install:** download `Marduk.dmg`\n- not a note"
        let json = "{\"tag_name\": \"v0.4.0\", \"body\": \(jsonString(body))}"
        let release = ReleaseCheck.parseLatestRelease(json)
        XCTAssertEqual(release?.tag, "0.4.0")
        XCTAssertEqual(release?.notes, ["Fix the thing", "Add the feature"])
    }

    func testMissingBodyStillParsesTag() {
        let release = ReleaseCheck.parseLatestRelease(#"{"tag_name": "v0.4.0"}"#)
        XCTAssertEqual(release?.tag, "0.4.0")
        XCTAssertEqual(release?.notes, [])
    }

    private func jsonString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        let array = String(data: data, encoding: .utf8)!
        return String(array.dropFirst().dropLast()) // strip the [ ]
    }

    func testGarbageAndMissingKeyReturnNil() {
        XCTAssertNil(ReleaseCheck.parseLatestTag(""))
        XCTAssertNil(ReleaseCheck.parseLatestTag("not json"))
        XCTAssertNil(ReleaseCheck.parseLatestTag(#"{"message": "Not Found"}"#))
        XCTAssertNil(ReleaseCheck.parseLatestTag(#"{"tag_name": ""}"#))
        XCTAssertNil(ReleaseCheck.parseLatestTag(#"[1, 2, 3]"#))
    }

    // MARK: - nextPatch (the dd release gesture's only allowed bump)

    func testNextPatchIncrementsPatchOnly() {
        XCTAssertEqual(ReleaseCheck.nextPatch(after: "0.4.9"), "0.4.10")
        XCTAssertEqual(ReleaseCheck.nextPatch(after: "0.4.10"), "0.4.11")
        XCTAssertEqual(ReleaseCheck.nextPatch(after: "1.0.0"), "1.0.1")
    }

    func testNextPatchAcceptsTagPrefix() {
        // Input comes straight from `git tag --list 'v*'`
        XCTAssertEqual(ReleaseCheck.nextPatch(after: "v0.4.9"), "0.4.10")
    }

    func testNextPatchRejectsNonSemver() {
        XCTAssertNil(ReleaseCheck.nextPatch(after: ""))
        XCTAssertNil(ReleaseCheck.nextPatch(after: "0.4"))
        XCTAssertNil(ReleaseCheck.nextPatch(after: "0.4.9.1"))
        XCTAssertNil(ReleaseCheck.nextPatch(after: "0.4.x"))
        XCTAssertNil(ReleaseCheck.nextPatch(after: "release-candidate"))
    }

    // MARK: - stageLine (release.sh "==>" narration)

    func testStageLineStripsMarker() {
        XCTAssertEqual(ReleaseCheck.stageLine("==> Waiting for CI on the release commit"),
                       "Waiting for CI on the release commit")
        XCTAssertEqual(ReleaseCheck.stageLine("==> Notarizing the app "),
                       "Notarizing the app")
    }

    func testStageLineIgnoresOrdinaryOutput() {
        XCTAssertNil(ReleaseCheck.stageLine("Compiling marduk main.swift"))
        XCTAssertNil(ReleaseCheck.stageLine("==>"))
        XCTAssertNil(ReleaseCheck.stageLine("==> "))
        XCTAssertNil(ReleaseCheck.stageLine(" ==> indented does not count"))
    }
}
