import XCTest
@testable import marduk

/// Regression net for the 2026-07-22 hover deafness: the NSEvent global
/// mouse monitor installed cleanly and delivered zero events, and the
/// dwell logic was tangled in that plumbing where nothing could test it.
/// Now the decision core is pure (HoverDwell, injected clock) and the
/// event-monitor approach itself is fenced off by a tripwire below.
final class HoverDwellTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    func testMovementThenSettleSpeaksOnce() {
        var dwell = HoverDwell(point: p(0, 0), now: at(0))
        XCTAssertEqual(dwell.poll(point: p(100, 0), now: at(0.12)), .moving)
        // Still inside the settle delay — resting, not speaking
        XCTAssertEqual(dwell.poll(point: p(100, 0), now: at(0.24)), .resting)
        // Past the delay — speaks exactly once
        XCTAssertEqual(dwell.poll(point: p(100, 0), now: at(0.48)), .speak)
        XCTAssertEqual(dwell.poll(point: p(100, 0), now: at(0.60)), .resting)
        XCTAssertEqual(dwell.poll(point: p(100, 0), now: at(9.99)), .resting)
    }

    func testInitialRestNeverSpeaks() {
        // Activation speaks immediately outside the dwell, so the state
        // starts with the speak already owed — sitting still says nothing
        var dwell = HoverDwell(point: p(50, 50), now: at(0))
        XCTAssertEqual(dwell.poll(point: p(50, 50), now: at(1)), .resting)
        XCTAssertEqual(dwell.poll(point: p(51, 50), now: at(2)), .resting)
    }

    func testJitterDoesNotResetTheSettleClock() {
        var dwell = HoverDwell(point: p(0, 0), now: at(0))
        XCTAssertEqual(dwell.poll(point: p(40, 0), now: at(0.12)), .moving)
        // Hand tremor within the threshold of the rest point
        XCTAssertEqual(dwell.poll(point: p(42, 1), now: at(0.24)), .resting)
        XCTAssertEqual(dwell.poll(point: p(39, 2), now: at(0.36)), .resting)
        XCTAssertEqual(dwell.poll(point: p(41, 0), now: at(0.48)), .speak)
    }

    func testSlowGlideAccumulatesAndKeepsSpeaking() {
        // Sub-threshold creep must accumulate against the REST point,
        // not rebase every tick — a slow glide across a toolbar keeps
        // naming controls instead of being eaten 2 pixels at a time
        var dwell = HoverDwell(point: p(0, 0), now: at(0))
        XCTAssertEqual(dwell.poll(point: p(30, 0), now: at(0.12)), .moving)
        XCTAssertEqual(dwell.poll(point: p(30, 0), now: at(0.48)), .speak)
        // Creep 2px per tick: crosses the threshold on cumulative drift
        XCTAssertEqual(dwell.poll(point: p(32, 0), now: at(0.60)), .resting)
        XCTAssertEqual(dwell.poll(point: p(34, 0), now: at(0.72)), .moving)
        // …and the new rest speaks again after the delay
        XCTAssertEqual(dwell.poll(point: p(34, 0), now: at(1.10)), .speak)
    }

    func testMovementDuringSettleRestartsTheClock() {
        var dwell = HoverDwell(point: p(0, 0), now: at(0))
        XCTAssertEqual(dwell.poll(point: p(100, 0), now: at(0.12)), .moving)
        XCTAssertEqual(dwell.poll(point: p(200, 0), now: at(0.24)), .moving)
        // Only 0.2s at the NEW rest point — not yet
        XCTAssertEqual(dwell.poll(point: p(200, 0), now: at(0.44)), .resting)
        XCTAssertEqual(dwell.poll(point: p(200, 0), now: at(0.55)), .speak)
    }

    /// PROHIBITION tripwire (field 2026-07-22): an NSEvent global mouse
    /// monitor installed cleanly (non-nil) in the background daemon and
    /// delivered ZERO events — hover spoke once at toggle, then went
    /// deaf. Pointer tracking in this daemon POLLS NSEvent.mouseLocation;
    /// if this test fails, someone reintroduced the broken approach.
    func testHoverNeverUsesNSEventGlobalMonitors() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MardukTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/Input/HoverSpeech.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertFalse(text.contains("addGlobalMonitorForEvents"),
                       "HoverSpeech must poll the pointer, never rely on NSEvent "
                       + "global monitors — they silently deliver nothing to the "
                       + "background daemon (field 2026-07-22)")
        XCTAssertTrue(text.contains("mouseLocation"),
                      "HoverSpeech should track the pointer by polling "
                      + "NSEvent.mouseLocation")
    }
}
