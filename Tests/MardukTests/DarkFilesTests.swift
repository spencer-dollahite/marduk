import XCTest
import AppKit
@testable import marduk

/// Files that measured 0% executed.
///
/// Each holds a decision with real consequences behind a shell call, a
/// plist write, or an AppKit type — so the logic was never run by anything
/// but the daemon itself. These extract the judgment and pin it.
final class DarkFilesTests: XCTestCase {

    // MARK: - ReleaseUpdater: the code that decides what reaches your Mac

    /// The one input an attacker-influenced release feed controls. A tag
    /// carrying `..` or a slash must never be interpolated into a path.
    func testAssetURLRefusesAnythingButAPlainVersion() {
        XCTAssertNotNil(ReleaseUpdater.assetURL(tag: "0.4.11"))
        for bad in ["../../evil", "0.4.11/../../x", "latest", "",
                    "0.4", "0.4.11.1", "v0.4.11", "0.4.11 ", "0.4.x"] {
            XCTAssertNil(ReleaseUpdater.assetURL(tag: bad),
                         "tag '\(bad)' must not produce a download URL")
        }
    }

    /// HTTPS, github.com, and the VERSIONED path — never the floating
    /// `latest` link, which could move between the check and the swap.
    func testAssetURLIsHTTPSVersionedAndOnGitHub() throws {
        let raw = try XCTUnwrap(ReleaseUpdater.assetURL(tag: "0.4.11"))
        let url = try XCTUnwrap(URL(string: raw))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "github.com")
        XCTAssertTrue(raw.contains("/releases/download/v0.4.11/"),
                      "the asset URL must pin the version")
        XCTAssertFalse(raw.contains("releases/latest"))
        XCTAssertFalse(raw.contains("/vv"), "the v prefix must not double up")
    }

    /// THE security gate. Three checks run on the STAGED copy before the
    /// live bundle is touched; nothing else in the repo would notice if a
    /// refactor deleted one.
    func testAllThreeVerificationGatesSurvive() {
        let gates = ReleaseUpdater.verificationGates(staging: "/tmp/staged.app")
        XCTAssertEqual(gates.count, 3, "a verification gate disappeared")

        let flat = gates.map { $0.joined(separator: " ") }
        XCTAssertTrue(flat.contains { $0.contains("codesign") && $0.contains("--strict")
                                        && $0.contains("--deep") },
                      "lost the strict signature check")
        XCTAssertTrue(flat.contains { $0.contains("-R=") },
                      "lost the PINNED designated requirement check")
        XCTAssertTrue(flat.contains { $0.contains("spctl") && $0.contains("--assess") },
                      "lost the notarization assessment")
    }

    /// Every gate must target the STAGED copy. One pointed at the live
    /// bundle would verify the thing already installed and pass trivially.
    func testEveryGateVerifiesTheStagedCopy() {
        for gate in ReleaseUpdater.verificationGates(staging: "/tmp/staged.app") {
            XCTAssertTrue(gate.contains("/tmp/staged.app"),
                          "gate \(gate[0]) does not verify the staged copy")
        }
    }

    func testFailuresAllSpeakSomethingUseful() {
        for failure in [ReleaseUpdater.Failure.download, .mount,
                        .verification, .install] {
            XCTAssertFalse(failure.spoken.isEmpty)
            // Spoken lines end in terminal punctuation so the synthesizer
            // gives them a falling close rather than running on.
            XCTAssertTrue(failure.spoken.hasSuffix(".")
                            || failure.spoken.hasSuffix("?"),
                          "'\(failure.spoken)' does not end a sentence")
        }
    }

    // MARK: - Codesign: which identity a build gets signed with

    private let securityOutput = """
          1) AAAA1111 "Apple Development: Someone (TEAM1)"
          2) BBBB2222 "Developer ID Application: Spencer Dollahite (X56UYJ5NDJ)"
          3) CCCC3333 "Mac Developer: Someone Else (TEAM2)"
             3 valid identities found
        """

    /// Preference order is load-bearing and invisible: ONLY a Developer ID
    /// Application certificate produces a build that can satisfy
    /// `ReleaseUpdater.requirement`. Picking an Apple Development identity
    /// when a Developer ID exists silently makes releases unverifiable.
    func testDeveloperIDWinsOverEveryOtherIdentity() {
        XCTAssertEqual(
            Codesign.firstIdentity(inSecurityOutput: securityOutput),
            "Developer ID Application: Spencer Dollahite (X56UYJ5NDJ)")
    }

    func testFallsBackThroughThePreferenceOrder() {
        let noDevID = """
              1) CCCC3333 "Mac Developer: Someone (TEAM2)"
              2) AAAA1111 "Apple Development: Someone (TEAM1)"
            """
        XCTAssertEqual(Codesign.firstIdentity(inSecurityOutput: noDevID),
                       "Apple Development: Someone (TEAM1)",
                       "Apple Development outranks Mac Developer")
    }

    func testNoIdentitiesFoundYieldsNil() {
        XCTAssertNil(Codesign.firstIdentity(inSecurityOutput: "     0 valid identities found"))
        XCTAssertNil(Codesign.firstIdentity(inSecurityOutput: ""))
    }

    /// An unrecognised identity type is still better than refusing to
    /// sign — but a quoteless line must not crash the parse.
    func testMalformedLinesAreSkipped() {
        let messy = """
              1) DDDD4444 no quotes here
              2) EEEE5555 "Some Other Kind: Person (TEAM3)"
            """
        XCTAssertEqual(Codesign.firstIdentity(inSecurityOutput: messy),
                       "Some Other Kind: Person (TEAM3)")
    }

    // MARK: - LaunchAgent: the job description the daemon's life depends on

    /// Every key here is load-bearing, and a missing one fails only at
    /// runtime, on a user's Mac, after an install.
    func testPlistCarriesEveryKeyTheLifecycleNeeds() throws {
        let plist = LaunchAgent.plistDictionary(binaryPath: "/Applications/Marduk.app/Contents/MacOS/marduk")

        XCTAssertEqual(plist["Label"] as? String, Codesign.identifier,
                       "the launchd label is half the identity trio")
        XCTAssertEqual(plist["ProgramArguments"] as? [String],
                       ["/Applications/Marduk.app/Contents/MacOS/marduk",
                        "start", "--foreground"],
                       "without --foreground the agent spawns a process that "
                       + "exits instantly, forever")
        XCTAssertEqual(plist["KeepAlive"] as? [String: Bool],
                       ["SuccessfulExit": false],
                       "this is the whole crash-relaunch contract, and what "
                       + "makes the exit-75 update restart work")
        XCTAssertEqual(plist["AbandonProcessGroup"] as? Bool, true,
                       "without it launchd SIGKILLs the migration helper "
                       + "along with the daemon it is replacing")
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
    }

    /// It must actually serialize — a non-plist value type fails only when
    /// the user runs `marduk install`.
    func testPlistSerializesAndRoundTrips() throws {
        let plist = LaunchAgent.plistDictionary(binaryPath: "/tmp/marduk")
        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                      format: .xml, options: 0)
        XCTAssertEqual(LaunchAgent.programPath(fromPlistData: data), "/tmp/marduk",
                       "the migration detector must read back what we wrote")
    }

    func testProgramPathHandlesJunkWithoutCrashing() {
        XCTAssertNil(LaunchAgent.programPath(fromPlistData: Data()))
        XCTAssertNil(LaunchAgent.programPath(fromPlistData: Data("not a plist".utf8)))
    }

    /// `launchctl print` indents, repeats `state =` for sub-components, and
    /// may carry no pid. A parse regression reads as "everything is fine"
    /// while the daemon is dead.
    func testLaunchctlSummaryTakesTheFirstStateAndPid() {
        let output = """
            com.marduk.daemon = {
                state = running
                pid = 4242
                spawn type = daemon
                state = waiting
            }
            """
        XCTAssertEqual(LaunchAgent.summarize(printOutput: output),
                       "state = running, pid = 4242")
    }

    func testLoadedButNotRunningStillSummarizes() {
        XCTAssertEqual(LaunchAgent.summarize(printOutput: "  state = waiting\n"),
                       "state = waiting")
        XCTAssertEqual(LaunchAgent.summarize(printOutput: "nothing useful here"),
                       "loaded", "an unparseable print must not read as running")
    }

    // MARK: - ModeOverlay: whether a mode is visible at all

    /// A parse regression makes a mode invisible, and telling NORMAL from
    /// INSERT at a glance is the overlay's entire job.
    func testColorsParseInEveryAcceptedForm() {
        XCTAssertNotNil(ModeOverlay.parseColor("#FF3B30"))
        XCTAssertNotNil(ModeOverlay.parseColor("ff3b30"), "the hash is optional")
        XCTAssertNotNil(ModeOverlay.parseColor("  #34C759  "), "whitespace trims")
    }

    /// "none" is how a user hides one mode's indicator — it must stay
    /// distinguishable from a typo, which also yields nil but logs.
    func testNoneAndEmptyHideTheMode() {
        XCTAssertNil(ModeOverlay.parseColor("none"))
        XCTAssertNil(ModeOverlay.parseColor("NONE"))
        XCTAssertNil(ModeOverlay.parseColor(""))
    }

    func testMalformedColorsAreRejectedNotGuessed() {
        for bad in ["#FFF", "#GGGGGG", "#FF3B3", "#FF3B3030", "red", "#"] {
            XCTAssertNil(ModeOverlay.parseColor(bad),
                         "'\(bad)' must not resolve to a colour")
        }
    }

    /// The shipped defaults must all be parseable, or a fresh install has
    /// invisible modes.
    func testEveryDefaultOverlayColorParses() {
        let overlay = MardukConfig.OverlayConfig()
        for raw in [overlay.normalColor, overlay.insertColor,
                    overlay.visualColor, overlay.readingColor] {
            let value = try? XCTUnwrap(raw)
            XCTAssertNotNil(ModeOverlay.parseColor(value ?? ""),
                            "default colour \(raw ?? "nil") does not parse")
        }
    }
}
