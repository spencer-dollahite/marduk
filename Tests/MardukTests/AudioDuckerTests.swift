import XCTest
@testable import marduk

/// The ducker's volume ramp. Two properties, both of which were violated
/// by the original inline loop and neither of which was reachable by a
/// test, because the arithmetic lived inside an AppleScript string built
/// on a serial dispatch queue.
final class AudioDuckerTests: XCTestCase {

    /// `for i in 1...steps` TRAPPED on a non-positive step count. Nothing
    /// validates `ducking.rampSteps` — it isn't a `:config` key, so the
    /// only way to set it is a hand-edit, which is exactly the path that
    /// skips every guard. A zero there took the daemon down on the first
    /// duck, and KeepAlive would relaunch it straight into another one.
    func testNonPositiveStepCountDoesNotTrap() {
        for steps in [0, -1, -100] {
            let volumes = AudioDucker.rampVolumes(from: 80, to: 5, steps: steps)
            XCTAssertEqual(volumes, [5], "a degenerate step count must still "
                           + "land on the target volume, not crash")
        }
    }

    /// A ramp that doesn't finish exactly on its target leaves the user's
    /// volume adrift — and the drift compounds across duck/unduck cycles.
    func testRampAlwaysLandsExactlyOnTarget() {
        for steps in 1...40 {
            for (from, to) in [(100, 5), (5, 100), (50, 50), (0, 100), (100, 0)] {
                let volumes = AudioDucker.rampVolumes(from: from, to: to, steps: steps)
                XCTAssertEqual(volumes.count, steps)
                XCTAssertEqual(volumes.last, to,
                               "ramp \(from)->\(to) in \(steps) missed its target")
            }
        }
    }

    func testRampStaysInRangeAndMovesMonotonically() {
        let down = AudioDucker.rampVolumes(from: 90, to: 10, steps: 8)
        XCTAssertTrue(down.allSatisfy { (0...100).contains($0) })
        XCTAssertEqual(down, down.sorted(by: >), "a duck must not rise mid-ramp")

        let up = AudioDucker.rampVolumes(from: 10, to: 90, steps: 8)
        XCTAssertTrue(up.allSatisfy { (0...100).contains($0) })
        XCTAssertEqual(up, up.sorted(), "a restore must not dip mid-ramp")
    }

    func testSingleStepJumpsStraightToTarget() {
        XCTAssertEqual(AudioDucker.rampVolumes(from: 70, to: 5, steps: 1), [5])
    }

    /// An out-of-range persisted level can't push the ramp out of bounds.
    func testExtremeEndpointsAreClamped() {
        let volumes = AudioDucker.rampVolumes(from: 500, to: -300, steps: 5)
        XCTAssertTrue(volumes.allSatisfy { (0...100).contains($0) })
        XCTAssertEqual(volumes.last, 0)
    }
}
