import XCTest
import ApplicationServices
@testable import marduk

/// The cursor-placement ledger's pure judgment: R trusts the caret (and
/// the pointer, and the row estimate) only in a window the user has
/// actually touched — a reopened document's restored caret is
/// byte-identical to a clicked one in AX, so the evidence comes from the
/// event tap instead. Every unknown must degrade toward trusting the
/// caret (today's behavior): a wrongly-forced top strands a working
/// caret with no gesture back.
final class CursorLedgerTests: XCTestCase {

    // MARK: - Click geometry

    func testClickInsideFrameBlesses() {
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertTrue(KeyboardMonitor.clickPlacedCursor(
            [CGPoint(x: 250, y: 200)], within: frame))
    }

    func testClickOutsideFrameDoesNot() {
        // Template-chooser / toolbar / open-panel clicks: same app, not
        // in the text area — must not bless a restored caret
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertFalse(KeyboardMonitor.clickPlacedCursor(
            [CGPoint(x: 50, y: 50), CGPoint(x: 600, y: 500)], within: frame))
    }

    func testAnyHitAmongMissesBlesses() {
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertTrue(KeyboardMonitor.clickPlacedCursor(
            [CGPoint(x: 50, y: 50), CGPoint(x: 250, y: 200)], within: frame))
    }

    func testNoClicksNeverBless() {
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertFalse(KeyboardMonitor.clickPlacedCursor([], within: frame))
        XCTAssertFalse(KeyboardMonitor.clickPlacedCursor([], within: nil))
    }

    func testUnknownFrameTrustsAnyClick() {
        // No frame to judge against — unknowns trust the caret
        XCTAssertTrue(KeyboardMonitor.clickPlacedCursor(
            [CGPoint(x: 1, y: 1)], within: nil))
    }

    // MARK: - Typed-window identity

    // AXUIElement application tokens are pure local handles (no IPC, no
    // TCC): two tokens for the same PID are CFEqual, different PIDs are
    // not — exactly the identity the ledger stores.

    func testEmptyLedgerNeverBlesses() {
        let win = AXUIElementCreateApplication(getpid())
        XCTAssertFalse(KeyboardMonitor.windowTyped(win, in: []))
        XCTAssertFalse(KeyboardMonitor.windowTyped(nil, in: []))
    }

    func testMatchingWindowBlesses() {
        let marked = AXUIElementCreateApplication(getpid())
        let sameAgain = AXUIElementCreateApplication(getpid())
        XCTAssertTrue(KeyboardMonitor.windowTyped(sameAgain, in: [marked]))
    }

    func testDifferentWindowDoesNot() {
        // Per-window granularity: typing in doc A never blesses doc B
        let marked = AXUIElementCreateApplication(getpid())
        let other = AXUIElementCreateApplication(1)  // launchd's PID
        XCTAssertFalse(KeyboardMonitor.windowTyped(other, in: [marked]))
    }

    func testUnresolvableWindowTrustsAnyTypedWindow() {
        // The element answered no AXWindow — can't distinguish, and
        // unknowns trust the caret
        let marked = AXUIElementCreateApplication(getpid())
        XCTAssertTrue(KeyboardMonitor.windowTyped(nil, in: [marked]))
    }
}
