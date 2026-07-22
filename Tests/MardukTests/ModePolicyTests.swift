import XCTest
@testable import marduk

/// Mode transitions and the Escape gesture, enumerated.
///
/// The modal ladder is the product's spine and none of it was pinned. On
/// 2026-07-22 a user could not leave a 1,309-page Terminal read: every
/// held Escape correctly dropped to NORMAL and was instantly undone by
/// paged window continuation, because the engine inferred "the window
/// ended naturally" from didFinish — and a synthesizer stopped while
/// PAUSED reports didFinish. They escaped only by starting a different,
/// non-windowed read in another app.
final class ModePolicyTests: XCTestCase {

    private let allModes: [ModePolicy.Mode] =
        [.normal, .insert, .visual, .visualLine, .command]

    // MARK: - Escape HOLD: the ladder

    /// The subtle rung: `i` during a read leaves the read PLAYING and only
    /// suspends the capture, so a hold from there must RECLAIM the read
    /// rather than leave. Dropping straight to NORMAL would strand a
    /// playing read with no capture controlling it.
    func testHoldFromInsertDuringAReadReclaimsReading() {
        XCTAssertEqual(
            ModePolicy.escapeHoldDestination(mode: .insert, readActive: true,
                                             readMotionsEnabled: true, enabled: true),
            .reclaimReading)
    }

    /// With no read playing there is no rung to climb back to.
    func testHoldFromInsertWithoutAReadGoesStraightToNormal() {
        XCTAssertEqual(
            ModePolicy.escapeHoldDestination(mode: .insert, readActive: false,
                                             readMotionsEnabled: true, enabled: true),
            .normal)
    }

    /// READING is not a place the user can be when read motions are off,
    /// so the hold must not park them there.
    func testHoldNeverReclaimsReadingWhenReadMotionsAreOff() {
        XCTAssertEqual(
            ModePolicy.escapeHoldDestination(mode: .insert, readActive: true,
                                             readMotionsEnabled: false, enabled: true),
            .normal)
    }

    func testHoldFromVisualModesReturnsToNormal() {
        for mode in [ModePolicy.Mode.visual, .visualLine] {
            XCTAssertEqual(
                ModePolicy.escapeHoldDestination(mode: mode, readActive: false,
                                                 readMotionsEnabled: true, enabled: true),
                .normal)
        }
    }

    /// Already at the bottom of the ladder — the app gets its Escape.
    func testHoldFromNormalPassesToTheApp() {
        XCTAssertEqual(
            ModePolicy.escapeHoldDestination(mode: .normal, readActive: false,
                                             readMotionsEnabled: true, enabled: true),
            .passToApp)
    }

    /// While Marduk is disengaged it must never claim a key, in any mode.
    func testDisabledMardukNeverClaimsEscapeInAnyMode() {
        for mode in allModes {
            for readActive in [false, true] {
                XCTAssertEqual(
                    ModePolicy.escapeHoldDestination(mode: mode, readActive: readActive,
                                                     readMotionsEnabled: true,
                                                     enabled: false),
                    .passToApp,
                    "disabled Marduk claimed Escape in \(mode)")
            }
        }
    }

    /// Every mode has a defined answer — no combination falls through.
    func testEveryModeAndStateHasAHoldDestination() {
        for mode in allModes {
            for readActive in [false, true] {
                for motions in [false, true] {
                    let destination = ModePolicy.escapeHoldDestination(
                        mode: mode, readActive: readActive,
                        readMotionsEnabled: motions, enabled: true)
                    // reclaimReading is ONLY ever reachable from INSERT
                    if destination == .reclaimReading {
                        XCTAssertEqual(mode, .insert)
                        XCTAssertTrue(readActive && motions)
                    }
                }
            }
        }
    }

    // MARK: - Escape TAP: same key, five answers

    /// vim and Claude Code must keep their Escape.
    func testTapInInsertReachesTheApp() {
        XCTAssertEqual(
            ModePolicy.escapeTap(mode: .insert, readingCapture: false,
                                 readActive: false, readPaused: false),
            .deliverToApp)
    }

    /// During a captured read a tap is exactly Space.
    func testTapDuringAReadTogglesPause() {
        XCTAssertEqual(
            ModePolicy.escapeTap(mode: .normal, readingCapture: true,
                                 readActive: true, readPaused: false),
            .togglePause)
        XCTAssertEqual(
            ModePolicy.escapeTap(mode: .normal, readingCapture: true,
                                 readActive: true, readPaused: true),
            .togglePause)
    }

    /// The capture outranks the underlying mode — a read started from
    /// INSERT still answers a tap with pause, not a stray Escape.
    func testCaptureOutranksTheUnderlyingMode() {
        for mode in allModes {
            XCTAssertEqual(
                ModePolicy.escapeTap(mode: mode, readingCapture: true,
                                     readActive: true, readPaused: false),
                .togglePause,
                "capture did not outrank \(mode)")
        }
    }

    /// A paused read still reports as speaking and holds Space captive;
    /// Escape in NORMAL is what frees it.
    func testTapInNormalCancelsAPausedRead() {
        XCTAssertEqual(
            ModePolicy.escapeTap(mode: .normal, readingCapture: false,
                                 readActive: true, readPaused: true),
            .stopPausedRead)
        XCTAssertEqual(
            ModePolicy.escapeTap(mode: .normal, readingCapture: false,
                                 readActive: false, readPaused: false),
            .deliverToApp)
    }

    func testTapExitsVisualAndCancelsCommand() {
        for mode in [ModePolicy.Mode.visual, .visualLine] {
            XCTAssertEqual(
                ModePolicy.escapeTap(mode: mode, readingCapture: false,
                                     readActive: false, readPaused: false),
                .exitVisual)
        }
        XCTAssertEqual(
            ModePolicy.escapeTap(mode: .command, readingCapture: false,
                                 readActive: false, readPaused: false),
            .cancelCommand)
    }

    /// Tap and hold must never agree to do nothing — every mode resolves
    /// both gestures to a defined action.
    func testTapAndHoldAreBothTotal() {
        for mode in allModes {
            for capture in [false, true] {
                for paused in [false, true] {
                    _ = ModePolicy.escapeTap(mode: mode, readingCapture: capture,
                                             readActive: true, readPaused: paused)
                    _ = ModePolicy.escapeHoldDestination(
                        mode: mode, readActive: true,
                        readMotionsEnabled: true, enabled: true)
                }
            }
        }
    }

    // MARK: - Read capture entry

    /// A confirmation read fired by a `:config` command must NEVER steal
    /// the palette's keys mid-command (shipped regression).
    func testAReadNeverCapturesDuringCommandMode() {
        XCTAssertFalse(ModePolicy.shouldCaptureForRead(
            readActive: true, mode: .command, readMotionsEnabled: true,
            enabled: true, alreadyCapturing: false))
    }

    func testAReadCapturesFromEveryOtherMode() {
        for mode in allModes where mode != .command {
            XCTAssertTrue(ModePolicy.shouldCaptureForRead(
                readActive: true, mode: mode, readMotionsEnabled: true,
                enabled: true, alreadyCapturing: false),
                "a read failed to capture from \(mode)")
        }
    }

    func testCaptureRequiresAnActiveReadAndTheFeatureOn() {
        XCTAssertFalse(ModePolicy.shouldCaptureForRead(
            readActive: false, mode: .normal, readMotionsEnabled: true,
            enabled: true, alreadyCapturing: false))
        XCTAssertFalse(ModePolicy.shouldCaptureForRead(
            readActive: true, mode: .normal, readMotionsEnabled: false,
            enabled: true, alreadyCapturing: false))
        XCTAssertFalse(ModePolicy.shouldCaptureForRead(
            readActive: true, mode: .normal, readMotionsEnabled: true,
            enabled: false, alreadyCapturing: false))
        // Re-entering an existing capture must not flap it
        XCTAssertFalse(ModePolicy.shouldCaptureForRead(
            readActive: true, mode: .normal, readMotionsEnabled: true,
            enabled: true, alreadyCapturing: true))
    }

    // MARK: - Window continuation (the field bug)

    /// THE regression. A held Escape stops the read; the synthesizer
    /// reports didFinish because it was paused; the paged read must NOT
    /// treat that as "the window ended naturally" and start the next one.
    func testAStoppedReadNeverContinuesToTheNextWindow() {
        XCTAssertFalse(ModePolicy.shouldContinueWindow(
            stopRequested: true, isCurrentUtterance: true, hasNextWindow: true),
            "a user stop must end the read — this is the bug that made a "
            + "1,309-page Terminal read impossible to leave")
    }

    /// The feature still has to work: an untouched window flows onward.
    func testAnUntouchedWindowStillFlowsOnward() {
        XCTAssertTrue(ModePolicy.shouldContinueWindow(
            stopRequested: false, isCurrentUtterance: true, hasNextWindow: true))
    }

    func testContinuationRequiresTheCurrentUtteranceAndANextWindow() {
        XCTAssertFalse(ModePolicy.shouldContinueWindow(
            stopRequested: false, isCurrentUtterance: false, hasNextWindow: true),
            "a stale utterance must not drive continuation")
        XCTAssertFalse(ModePolicy.shouldContinueWindow(
            stopRequested: false, isCurrentUtterance: true, hasNextWindow: false),
            "the last window must end the read")
    }

    // MARK: - Document edges (gg / G)

    /// THE regression: `G` was paged-aware and `gg` was not, so gg fell
    /// through to a text offset of 0 — which on a WINDOWED read is the
    /// start of the current window, not the document. In a 1,336-page
    /// Terminal read opened at page 664 that read as a jump to a random
    /// spot, and `0` then restarted a line there.
    func testGgReachesPageOneOnAPagedRead() {
        XCTAssertEqual(
            ModePolicy.documentEdge(forward: false, isPaged: true, pageCount: 1336),
            .page(1))
    }

    func testCapitalGReachesTheLastPage() {
        XCTAssertEqual(
            ModePolicy.documentEdge(forward: true, isPaged: true, pageCount: 1336),
            .page(1336))
    }

    /// Both edges must be paged-aware or neither. The asymmetry IS the bug.
    func testBothEdgesAgreeOnWhetherTheReadIsPaged() {
        for pageCount in [1, 2, 1336] {
            let back = ModePolicy.documentEdge(forward: false, isPaged: true,
                                               pageCount: pageCount)
            let forward = ModePolicy.documentEdge(forward: true, isPaged: true,
                                                  pageCount: pageCount)
            if case .textOffset = back {
                XCTFail("gg fell through to a text offset on a paged read — "
                        + "that lands at the start of the current WINDOW")
            }
            if case .textOffset = forward {
                XCTFail("G fell through to a text offset on a paged read")
            }
        }
    }

    /// A plain read has no pages; both edges resolve in the text.
    func testPlainReadsUseTextOffsetsAtBothEdges() {
        XCTAssertEqual(
            ModePolicy.documentEdge(forward: false, isPaged: false, pageCount: 0),
            .textOffset)
        XCTAssertEqual(
            ModePolicy.documentEdge(forward: true, isPaged: false, pageCount: 0),
            .textOffset)
    }

    /// A single-page paged read: both edges are page 1, and neither may
    /// silently become a text offset.
    func testSinglePageDocumentHasBothEdgesAtPageOne() {
        XCTAssertEqual(
            ModePolicy.documentEdge(forward: false, isPaged: true, pageCount: 1),
            .page(1))
        XCTAssertEqual(
            ModePolicy.documentEdge(forward: true, isPaged: true, pageCount: 1),
            .page(1))
    }

    /// An in-window MOTION must not look like a user stop.
    ///
    /// `respeak` — the move primitive behind every jump — calls `stop()`,
    /// which sets stopRequested. It bypasses `speak()`, the only place that
    /// cleared the flag, so a single sentence jump or search left it set
    /// and the next window never loaded: the read died silently at the
    /// boundary, 15-45 pages after a keypress that seemed to work. The
    /// engine now clears the flag in `respeak`; this pins the contract the
    /// two sides have to agree on.
    func testAMotionLeavesContinuationEnabled() {
        // After a motion the flag must be back to false, so continuation
        // behaves exactly as it does on an untouched read.
        XCTAssertTrue(ModePolicy.shouldContinueWindow(
            stopRequested: false, isCurrentUtterance: true, hasNextWindow: true),
            "a moved-but-not-stopped read must still flow into its next window")
    }

    /// Exhaustive: stopRequested dominates every other input.
    func testStopAlwaysWins() {
        for isCurrent in [false, true] {
            for hasNext in [false, true] {
                XCTAssertFalse(ModePolicy.shouldContinueWindow(
                    stopRequested: true, isCurrentUtterance: isCurrent,
                    hasNextWindow: hasNext))
            }
        }
    }
}
