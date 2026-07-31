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

    // MARK: - Pre-watch snapshots

    // The daemon restarts on every self-update, so the apps the user
    // lives in almost always predate the monitor (field 2026-07-31: a
    // brand-new Pages doc read from the pointer because the app-level
    // launchDate gate trusted the whole app). The window snapshot keeps
    // per-window judgment for those apps.

    func testWindowInSnapshotPredatesWatch() {
        // A window already open at sweep time keeps the old
        // trust-the-caret behavior
        let snapshotted = AXUIElementCreateApplication(getpid())
        let sameAgain = AXUIElementCreateApplication(getpid())
        XCTAssertTrue(KeyboardMonitor.windowPredatesWatch(
            sameAgain, snapshot: [snapshotted]))
    }

    func testWindowAbsentFromSnapshotIsFresh() {
        // The fresh-Pages-doc case: pre-watch app, window that appeared
        // after the sweep — the caret must be earned
        let snapshotted = AXUIElementCreateApplication(1)  // launchd's PID
        let newWindow = AXUIElementCreateApplication(getpid())
        XCTAssertFalse(KeyboardMonitor.windowPredatesWatch(
            newWindow, snapshot: [snapshotted]))
    }

    func testEmptySnapshotIsARealAnswer() {
        // The app had no windows at sweep time — every later window is
        // fresh under our watch
        let newWindow = AXUIElementCreateApplication(getpid())
        XCTAssertFalse(KeyboardMonitor.windowPredatesWatch(
            newWindow, snapshot: []))
    }

    func testMissingSnapshotTrustsTheCaret() {
        // Sweep failed / AX denied / app appeared mid-sweep — unknown
        // history degrades to the old behavior
        let window = AXUIElementCreateApplication(getpid())
        XCTAssertTrue(KeyboardMonitor.windowPredatesWatch(
            window, snapshot: nil))
    }

    func testUnresolvableWindowTrustsTheCaret() {
        let snapshotted = AXUIElementCreateApplication(getpid())
        XCTAssertTrue(KeyboardMonitor.windowPredatesWatch(
            nil, snapshot: [snapshotted]))
    }
}
