import XCTest
@testable import marduk

/// The `dd` release gesture and the script it drives.
///
/// A release reaches strangers' machines: it tags, pushes, notarizes, and
/// publishes to everyone on the update train. Everything guarding that —
/// source-install only, one at a time, ask before acting, and the exact
/// version derived from the tag list — lived inside a method that spawns
/// a Process, so none of it was reachable by a test.
final class ReleaseFlowTests: XCTestCase {

    // MARK: - The gesture's gates

    /// A release install has no project dir. The keyboard gesture is
    /// already source-gated, but this is the backstop that makes a
    /// release impossible even if something else reaches the handler.
    func testReleasesAreImpossibleWithoutASourceCheckout() {
        XCTAssertEqual(
            ReleaseFlow.onCutReleaseKey(hasProjectDir: false, inFlight: false,
                                        stage: "starting"),
            .refuseNotSource)
        // …and being mid-flight doesn't unlock it either
        XCTAssertEqual(
            ReleaseFlow.onCutReleaseKey(hasProjectDir: false, inFlight: true,
                                        stage: "Notarizing the app"),
            .refuseNotSource)
    }

    /// `dd` during a run is the STATUS POKE — never a second release.
    func testSecondPressIsAStatusPokeNotAnotherRelease() {
        XCTAssertEqual(
            ReleaseFlow.onCutReleaseKey(hasProjectDir: true, inFlight: true,
                                        stage: "Waiting for CI on the release commit"),
            .statusPoke(stage: "Waiting for CI on the release commit"))
    }

    func testFirstPressOnASourceCheckoutAsks() {
        XCTAssertEqual(
            ReleaseFlow.onCutReleaseKey(hasProjectDir: true, inFlight: false,
                                        stage: "starting"),
            .askToCut)
    }

    // MARK: - The confirmation

    /// ONLY `y` releases. The question exists so a release can never
    /// happen by accident — every other answer must decline.
    func testOnlyYStartsARelease() {
        XCTAssertEqual(ReleaseFlow.onAnswer("y"), .start)
        for key: Character in ["n", "Y", "N", "d", " ", "\u{1b}"] {
            XCTAssertEqual(ReleaseFlow.onAnswer(key), .decline,
                           "'\(key)' must not start a release")
        }
    }

    // MARK: - Outcome routing

    func testOnlyExitZeroCountsAsShipped() {
        XCTAssertEqual(
            ReleaseFlow.outcome(status: 0, timedOut: false, version: "0.4.11",
                                stage: "Done"),
            .live(version: "0.4.11"))
        XCTAssertEqual(
            ReleaseFlow.outcome(status: 1, timedOut: false, version: "0.4.11",
                                stage: "Notarizing the app"),
            .failed(stage: "Notarizing the app"))
    }

    /// A timeout is reported as a TIMEOUT, not a failure — a wedged
    /// notarization or a locked keychain is still in flight upstream, and
    /// needs a different response from a real failure.
    func testTimeoutIsDistinctFromFailure() {
        XCTAssertEqual(
            ReleaseFlow.outcome(status: 15, timedOut: true, version: "0.4.11",
                                stage: "Notarizing the app"),
            .timedOut(stage: "Notarizing the app"))
    }

    /// The watchdog terminates the process, which yields a non-zero exit —
    /// so a timed-out run must never be mistaken for success.
    func testATimedOutRunIsNeverReportedLive() {
        for status: Int32 in [1, 15, 143] {
            let outcome = ReleaseFlow.outcome(status: status, timedOut: true,
                                              version: "0.4.11", stage: "x")
            XCTAssertNotEqual(outcome, .live(version: "0.4.11"))
        }
    }

    func testSpokenLinesNameTheVersionOrTheStage() {
        XCTAssertEqual(ReleaseFlow.spoken(.live(version: "0.4.11")),
                       "Release 0.4.11 is live.")
        XCTAssertTrue(ReleaseFlow.spoken(.failed(stage: "Building the disk image"))
            .contains("Building the disk image"))
        XCTAssertTrue(ReleaseFlow.spoken(.timedOut(stage: "Notarizing the app"))
            .contains("Notarizing the app"))
    }

    // MARK: - Deriving the version to cut

    /// git already sorts with --sort=v:refname, so the newest is the last
    /// non-empty line. This answer becomes a real git tag.
    func testNextVersionComesFromTheNewestTag() {
        let tags = "v0.4.8\nv0.4.9\nv0.4.10\n"
        XCTAssertEqual(ReleaseCheck.newestTag(fromTagList: tags), "v0.4.10")
        XCTAssertEqual(ReleaseCheck.nextVersion(fromTagList: tags), "0.4.11")
    }

    func testTagListWhitespaceAndBlankLinesAreTolerated() {
        XCTAssertEqual(ReleaseCheck.nextVersion(fromTagList: "  v0.4.10  \n\n"),
                       "0.4.11")
        XCTAssertEqual(ReleaseCheck.nextVersion(fromTagList: "v0.4.10"), "0.4.11")
    }

    /// No tags, or unparseable ones, must ABORT the gesture — never guess
    /// a version, because the guess would be tagged and pushed.
    func testUnusableTagListYieldsNoVersion() {
        XCTAssertNil(ReleaseCheck.nextVersion(fromTagList: ""))
        XCTAssertNil(ReleaseCheck.nextVersion(fromTagList: "\n\n  \n"))
        XCTAssertNil(ReleaseCheck.nextVersion(fromTagList: "not-a-tag"))
        XCTAssertNil(ReleaseCheck.nextVersion(fromTagList: "v1.2"))
    }

    /// dd only ever bumps the PATCH — minor and major are a human
    /// judgment and stay with the manual script.
    func testDdOnlyEverBumpsThePatch() {
        XCTAssertEqual(ReleaseCheck.nextVersion(fromTagList: "v0.9.9"), "0.9.10")
        XCTAssertEqual(ReleaseCheck.nextVersion(fromTagList: "v1.0.0"), "1.0.1")
    }
}
