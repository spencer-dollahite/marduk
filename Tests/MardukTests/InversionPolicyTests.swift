import XCTest
@testable import marduk

/// The inverter's state machine, exercised EXHAUSTIVELY.
///
/// The mechanism is a blind toggle: it flips whatever the display is
/// actually doing. That makes "fired when it shouldn't" and "fired in the
/// wrong direction" the same class of bug, and on 2026-07-22 it blinded a
/// low-vision user three separate times in one day — none of it reachable
/// by a test, because the whole decision sat behind an osascript call.
///
/// Every permutation is enumerated here rather than sampled. The state
/// space is five booleans; there is no excuse for spot checks.
final class InversionPolicyTests: XCTestCase {

    private let lockout: TimeInterval = 1.5
    /// Comfortably past the lockout unless a test says otherwise.
    private let past: TimeInterval = 99

    private func resolve(wanted: Bool, believed: Bool, actual: Bool,
                         active: Bool = true,
                         since: TimeInterval? = nil) -> InversionPolicy.Decision {
        InversionPolicy.resolve(wanted: wanted, believed: believed, actual: actual,
                                active: active, sinceLastToggle: since ?? past,
                                lockout: lockout)
    }

    private let bools = [false, true]

    // MARK: - The invariant that matters most

    /// THE safety property: the toggle may fire ONLY when the display is
    /// genuinely not in the wanted state. Anything else flips a correct
    /// screen to a wrong one. Checked across every permutation.
    func testFiresOnlyOnAGenuineTransition() {
        for wanted in bools {
            for believed in bools {
                for actual in bools {
                    for active in bools {
                        let decision = resolve(wanted: wanted, believed: believed,
                                               actual: actual, active: active)
                        if case .fire = decision {
                            XCTAssertTrue(active, "fired while switched off")
                            XCTAssertNotEqual(
                                wanted, actual,
                                "fired a toggle onto a display already in the "
                                + "wanted state (wanted=\(wanted) actual=\(actual))")
                        }
                    }
                }
            }
        }
    }

    /// Belief NEVER decides. Reality does. Two states that differ only in
    /// what Marduk believed must reach the same decision.
    func testBeliefNeverChangesTheDecision() {
        for wanted in bools {
            for actual in bools {
                for active in bools {
                    let believingTrue = resolve(wanted: wanted, believed: true,
                                                actual: actual, active: active)
                    let believingFalse = resolve(wanted: wanted, believed: false,
                                                 actual: actual, active: active)
                    XCTAssertEqual(believingTrue, believingFalse,
                                   "belief altered the outcome for wanted=\(wanted) "
                                   + "actual=\(actual) active=\(active)")
                }
            }
        }
    }

    /// Whatever the outcome, the caller is told the REAL state so a stale
    /// flag can't survive the decision that consulted it.
    func testEveryActedDecisionReportsRealityAsEffective() {
        for wanted in bools {
            for believed in bools {
                for actual in bools {
                    switch resolve(wanted: wanted, believed: believed, actual: actual) {
                    case .noChange(let effective), .fire(let effective):
                        XCTAssertEqual(effective, actual)
                    case .inactive, .lockedOut:
                        XCTFail("unexpected gate at wanted=\(wanted) actual=\(actual)")
                    }
                }
            }
        }
    }

    // MARK: - The gates

    /// Opt-in is absolute: switched off, nothing is even considered.
    func testInactiveBlocksEveryPermutation() {
        for wanted in bools {
            for believed in bools {
                for actual in bools {
                    XCTAssertEqual(
                        resolve(wanted: wanted, believed: believed,
                                actual: actual, active: false),
                        .inactive)
                }
            }
        }
    }

    func testLockoutOutranksEverythingButTheOptInGate() {
        // Inside the lockout, even a genuine transition waits
        XCTAssertEqual(resolve(wanted: true, believed: false, actual: false,
                               since: lockout - 0.01),
                       .lockedOut)
        XCTAssertEqual(resolve(wanted: true, believed: false, actual: false,
                               since: lockout),
                       .fire(effective: false))
        // Off beats locked out — the report should be the more fundamental one
        XCTAssertEqual(resolve(wanted: true, believed: false, actual: false,
                               active: false, since: 0),
                       .inactive)
    }

    // MARK: - Field incidents, as named regressions

    /// 2026-07-22 #1: believed inverted, display actually normal, teardown
    /// asks to revert. Firing here INVERTS a dark-mode screen — the exact
    /// keystroke that blinded the user.
    func testStaleBeliefNeverFiresARevertOntoANormalDisplay() {
        XCTAssertEqual(resolve(wanted: false, believed: true, actual: false),
                       .noChange(effective: false))
    }

    /// 2026-07-22 #3: the same stale belief in the other direction made
    /// Marduk refuse to invert Pages, because it thought it already had.
    func testStaleBeliefNeverBlocksAGenuineInvert() {
        XCTAssertEqual(resolve(wanted: true, believed: true, actual: false),
                       .fire(effective: false))
    }

    /// 2026-07-22 #2: a display left inverted by an earlier run must still
    /// be reachable — the heartbeat has to be able to hand it back.
    func testStrandedInversionCanAlwaysBeReverted() {
        XCTAssertEqual(resolve(wanted: false, believed: false, actual: true),
                       .fire(effective: true))
        XCTAssertEqual(resolve(wanted: false, believed: true, actual: true),
                       .fire(effective: true))
    }

    // MARK: - Exit (the one place ownership counts)

    /// Quitting must never flip a display Marduk didn't invert, and never
    /// fire on a belief. Enumerated, since this is what blinded the user.
    func testExitRevertsOnlyWhatWeOwnAndCanSee() {
        for believed in bools {
            for actual in bools {
                for owned in bools {
                    let revert = InversionPolicy.shouldRevertOnExit(
                        believed: believed, actual: actual, owned: owned)
                    XCTAssertEqual(revert, believed && actual && owned)
                    if revert {
                        XCTAssertTrue(actual, "exit fired onto a normal display")
                        XCTAssertTrue(owned, "exit flipped someone else's inversion")
                    }
                }
            }
        }
    }

    func testExitLeavesAForeignInversionAlone() {
        XCTAssertFalse(InversionPolicy.shouldRevertOnExit(
            believed: true, actual: true, owned: false))
    }

    // MARK: - The two switches

    /// Either switch opts in. This one value gates inverting AND
    /// reverting, which is what makes them impossible to enable
    /// independently — incident #3 was exactly that asymmetry.
    func testEitherSwitchActivatesTheSubsystem() {
        XCTAssertFalse(InversionPolicy.isActive(invertEnabled: false, autoInvert: false))
        XCTAssertTrue(InversionPolicy.isActive(invertEnabled: true, autoInvert: false))
        XCTAssertTrue(InversionPolicy.isActive(invertEnabled: false, autoInvert: true))
        XCTAssertTrue(InversionPolicy.isActive(invertEnabled: true, autoInvert: true))
    }

    /// The structural guarantee: for every config permutation, the ability
    /// to invert and the ability to revert are the SAME answer. If these
    /// could ever differ, an inversion could be created that nothing was
    /// allowed to undo — a display stranded inverted forever.
    func testInvertAndRevertAreAlwaysEnabledTogether() {
        for invertEnabled in bools {
            for autoInvert in bools {
                let active = InversionPolicy.isActive(invertEnabled: invertEnabled,
                                                      autoInvert: autoInvert)
                let canInvert = resolve(wanted: true, believed: false,
                                        actual: false, active: active)
                let canRevert = resolve(wanted: false, believed: true,
                                        actual: true, active: active)
                let invertBlocked = canInvert == .inactive
                let revertBlocked = canRevert == .inactive
                XCTAssertEqual(invertBlocked, revertBlocked,
                               "invert and revert disagree at invert=\(invertEnabled) "
                               + "autoinvert=\(autoInvert) — an inversion could be "
                               + "created that nothing can undo")
            }
        }
    }
}
