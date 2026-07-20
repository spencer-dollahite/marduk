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

    func testGarbageAndMissingKeyReturnNil() {
        XCTAssertNil(ReleaseCheck.parseLatestTag(""))
        XCTAssertNil(ReleaseCheck.parseLatestTag("not json"))
        XCTAssertNil(ReleaseCheck.parseLatestTag(#"{"message": "Not Found"}"#))
        XCTAssertNil(ReleaseCheck.parseLatestTag(#"{"tag_name": ""}"#))
        XCTAssertNil(ReleaseCheck.parseLatestTag(#"[1, 2, 3]"#))
    }
}
