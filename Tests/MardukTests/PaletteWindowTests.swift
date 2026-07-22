import XCTest
@testable import marduk

/// The palette's visible slice, and two tripwires on key-dispatch fixes
/// that cannot be reached any other way.
///
/// All three pin bugs found by audit on 2026-07-22 and fixed together.
final class PaletteWindowTests: XCTestCase {

    private let maxRows = 16

    private func window(selected: Int, count: Int) -> Range<Int> {
        CommandPalette.visibleWindow(selected: selected, count: count,
                                     maxRows: maxRows)
    }

    // MARK: - The regression

    /// THE bug: the palette rendered a fixed `prefix(maxRows)` while the
    /// daemon wrapped the selection modulo the FULL candidate count. Past
    /// row 15 — routine in the voice picker — nothing was highlighted on
    /// screen while the selection kept moving invisibly.
    func testSelectionIsAlwaysInsideTheVisibleWindow() {
        for count in [1, 5, 16, 17, 40, 100] {
            for selected in 0..<count {
                let window = window(selected: selected, count: count)
                XCTAssertTrue(window.contains(selected),
                              "selection \(selected) of \(count) fell outside "
                              + "the visible window \(window) — it would be "
                              + "highlighted off-screen")
            }
        }
    }

    /// Short lists must not scroll at all — the common case.
    func testShortListsShowEverythingFromTheTop() {
        XCTAssertEqual(window(selected: 0, count: 5), 0..<5)
        XCTAssertEqual(window(selected: 4, count: 5), 0..<5)
        XCTAssertEqual(window(selected: 0, count: maxRows), 0..<maxRows)
    }

    /// Scroll the minimum distance, like a pager: stepping one past the
    /// bottom moves the window by exactly one.
    func testScrollingFollowsTheSelectionByTheSmallestStep() {
        XCTAssertEqual(window(selected: maxRows - 1, count: 40), 0..<maxRows)
        XCTAssertEqual(window(selected: maxRows, count: 40), 1..<(maxRows + 1))
        XCTAssertEqual(window(selected: maxRows + 1, count: 40), 2..<(maxRows + 2))
    }

    /// Wrapping from the last row back to the first (the daemon's selection
    /// is modulo the count) must bring the window home.
    func testWrappingToTheEndsLandsOnAFullWindow() {
        let last = window(selected: 39, count: 40)
        XCTAssertEqual(last, (40 - maxRows)..<40)
        XCTAssertEqual(window(selected: 0, count: 40), 0..<maxRows)
    }

    func testWindowIsAlwaysFullWhenThereAreEnoughRows() {
        for selected in 0..<40 {
            XCTAssertEqual(window(selected: selected, count: 40).count, maxRows,
                           "a partial window wastes rows and misreports overflow")
        }
    }

    func testDegenerateInputsAreSafe() {
        XCTAssertEqual(window(selected: 0, count: 0), 0..<0)
        XCTAssertEqual(CommandPalette.visibleWindow(selected: 0, count: 5,
                                                    maxRows: 0), 0..<0)
        // Out-of-range selections clamp rather than trapping
        XCTAssertTrue(window(selected: -5, count: 40).contains(0))
        XCTAssertTrue(window(selected: 999, count: 40).contains(39))
    }

    // MARK: - Tripwires on KeyboardMonitor
    //
    // The modal router is one 1,100-line method over CGEvent and cannot be
    // called from a test. Asserting on its SOURCE is the codebase's
    // established escape hatch for exactly this (see
    // HoverDwellTests' NSEvent-monitor tripwire and ReleaseScriptTests).

    private func keyboardMonitorSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MardukTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        return try String(
            contentsOf: root.appendingPathComponent("Sources/Input/KeyboardMonitor.swift"),
            encoding: .utf8)
    }

    /// NORMAL passed Cmd and Ctrl through but not Option, so Option+letter
    /// fired Marduk's bare command instead of reaching the app — while
    /// COMMAND mode passed Option through deliberately, because the user's
    /// zoom shortcuts ride on it.
    func testNormalModePassesOptionCombosToTheApp() throws {
        let source = try keyboardMonitorSource()
        XCTAssertTrue(
            source.contains("if hasCommand || hasControl || hasOption {"),
            "NORMAL mode must pass Option combos through — Option+letter "
            + "otherwise fires a command and never reaches the app")
    }

    /// The reading capture's buzz fallback lists every typing-shaped key.
    /// Space was absent, and the pause branch above it requires an
    /// UNSHIFTED Space — so Shift+Space fell through and typed a space
    /// into the user's document mid-read.
    func testShiftSpaceCannotLeakIntoTheAppDuringARead() throws {
        let source = try keyboardMonitorSource()
        XCTAssertTrue(
            source.contains("|| keycode == 49 {"),
            "Space must be in the reading buzz fallback, or Shift+Space "
            + "leaks into the app during a captured read")
    }
}
