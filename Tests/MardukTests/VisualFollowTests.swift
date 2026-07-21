import XCTest
@testable import marduk

final class VisualFollowTests: XCTestCase {

    func testDigitKeycodesTypeThePageNumber() {
        XCTAssertEqual(KeyboardMonitor.digitKeycodes(2), [19])
        XCTAssertEqual(KeyboardMonitor.digitKeycodes(12), [18, 19])
        XCTAssertEqual(KeyboardMonitor.digitKeycodes(305), [20, 29, 23])
        XCTAssertEqual(KeyboardMonitor.digitKeycodes(1234567890),
                       [18, 19, 20, 21, 23, 22, 26, 28, 25, 29])
        XCTAssertEqual(KeyboardMonitor.digitKeycodes(-3), [29])  // clamped to 0
    }

    func testPreviewHasAGoToPageChord() {
        let chord = KeyboardMonitor.pageChords["com.apple.Preview"]
        XCTAssertEqual(chord?.keycode, 5)  // G
        XCTAssertEqual(chord?.command, true)
        XCTAssertEqual(chord?.option, true)
        XCTAssertEqual(chord?.shift, false)
    }

    func testLineIndexCountsNewlinesBeforeOffset() {
        let text = "line one\nline two\nline three"
        XCTAssertEqual(KeyboardMonitor.lineIndex(of: 0, in: text), 0)
        XCTAssertEqual(KeyboardMonitor.lineIndex(of: 8, in: text), 0)   // end of line one
        XCTAssertEqual(KeyboardMonitor.lineIndex(of: 9, in: text), 1)   // first char of line two
        XCTAssertEqual(KeyboardMonitor.lineIndex(of: 18, in: text), 2)
        XCTAssertEqual(KeyboardMonitor.lineIndex(of: 999, in: text), 2) // clamped
        XCTAssertEqual(KeyboardMonitor.lineIndex(of: -1, in: text), 0)
    }
}
