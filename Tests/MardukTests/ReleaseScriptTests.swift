import XCTest
@testable import marduk

/// Tripwires on the REAL `scripts/release.sh`.
///
/// The script can't be executed in a test — it tags, pushes, notarizes,
/// and publishes. But two things about it are checkable and both are
/// load-bearing:
///
/// 1. Its safety guards still exist. They are the only thing standing
///    between the `dd` gesture and a bad release reaching every user on
///    the update train, and a refactor can delete a line silently.
/// 2. Its stage output still parses. The daemon's spoken status
///    ("Release in progress. <stage>.") comes from `ReleaseCheck.stageLine`
///    reading these exact lines — change the marker or emit an empty
///    stage and the narration goes silent with nothing failing.
///
/// Follows the `HoverDwellTests` NSEvent-monitor tripwire precedent:
/// assert on the source text of a thing that cannot be run.
final class ReleaseScriptTests: XCTestCase {

    /// Locate the repo from this file, so the test works regardless of
    /// the working directory the runner chose.
    private func releaseScript() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MardukTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let script = root.appendingPathComponent("scripts/release.sh")
        return try String(contentsOf: script, encoding: .utf8)
    }

    // MARK: - The guards

    /// Without `set -euo pipefail` a failing step is skipped rather than
    /// fatal, and the script would sail on to publish a broken release.
    func testScriptAbortsOnAnyError() throws {
        let script = try releaseScript()
        XCTAssertTrue(script.contains("set -euo pipefail"),
                      "release.sh must abort on the first error")
    }

    /// Every guard that has a reason to exist, with that reason.
    func testSafetyGuardsAreAllStillPresent() throws {
        let script = try releaseScript()
        let guards: [(needle: String, why: String)] = [
            ("git status --porcelain",
             "a dirty tree would ship uncommitted work"),
            ("--ff-only",
             "a divergent push once left a tag on an orphaned commit"),
            ("sort -V",
             "the monotonic guard — an older version poisons the update train"),
            ("gh run watch",
             "CI must be green before anything is published"),
            ("--exit-status",
             "gh run watch must FAIL the script on a red run, not just report"),
            ("codesign",
             "the release has to be signed or it cannot be notarized"),
            ("--options runtime",
             "notarization requires the hardened runtime"),
            ("notarytool",
             "an un-notarized DMG is blocked by Gatekeeper"),
            ("stapler",
             "stapling is what makes the artifacts verify offline"),
        ]
        for check in guards {
            XCTAssertTrue(script.contains(check.needle),
                          "release.sh lost '\(check.needle)' — \(check.why)")
        }
    }

    /// The monotonic guard must compare against BOTH the shipped version
    /// and the newest tag. Dropping either lets a version through that is
    /// older than one of them.
    func testMonotonicGuardChecksVersionAndNewestTag() throws {
        let script = try releaseScript()
        XCTAssertTrue(script.contains("Version.swift"),
                      "the monotonic guard must read the shipped version")
        XCTAssertTrue(script.contains("git tag --list"),
                      "the monotonic guard must read the newest tag")
        XCTAssertTrue(script.contains("is not greater than"),
                      "the monotonic guard must refuse a non-increasing version")
    }

    /// The version argument is interpolated into git tags, file paths, and
    /// URLs. It must be quoted at every use, or a value with a space
    /// silently splits into two arguments.
    func testVersionIsAlwaysQuoted() throws {
        let script = try releaseScript()
        XCTAssertFalse(script.contains("git tag v$VERSION"),
                       "unquoted $VERSION in git tag")
        XCTAssertFalse(script.contains("git tag $VERSION"),
                       "unquoted $VERSION in git tag")
        XCTAssertTrue(script.contains("\"${1:?") || script.contains("${1:?"),
                      "release.sh must refuse to run with no version argument")
    }

    /// The cask must pin the VERSIONED asset URL. `releases/latest` would
    /// break hash pinning and hand users an artifact whose sha256 doesn't
    /// match the cask.
    func testHomebrewCaskPinsAVersionedAsset() throws {
        let script = try releaseScript()
        guard script.contains("Casks/marduk.rb") else { return }
        // Scope to the cask's own url line — the script legitimately
        // MENTIONS releases/latest in a comment (the README's one-click
        // link uses it), so a whole-file search would be wrong.
        let urlLine = script.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("url \"https://github.com") }
        guard let urlLine else {
            return XCTFail("the cask no longer declares a url")
        }
        XCTAssertTrue(urlLine.contains("releases/download/v"),
                      "the cask must pin a VERSIONED asset URL: \(urlLine)")
        XCTAssertFalse(urlLine.contains("releases/latest"),
                       "the cask must never point at the floating latest link — "
                       + "the pinned sha256 would stop matching: \(urlLine)")
    }

    // MARK: - The narration contract

    /// EVERY stage the script prints must parse through the same function
    /// the daemon uses to narrate it. This is the coupling that silently
    /// breaks: change the marker, or emit `==>` with nothing after it, and
    /// `dd`'s status poke starts answering with a stale stage forever.
    func testEveryStageLineParsesForTheSpokenStatus() throws {
        let script = try releaseScript()
        var stages: [String] = []

        for raw in script.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // The literal stage announcements: echo "==> …"
            guard line.hasPrefix("echo \"==>") else { continue }
            guard let open = line.firstIndex(of: "\""),
                  let close = line.lastIndex(of: "\""), open < close else {
                return XCTFail("could not read the stage from: \(line)")
            }
            let text = String(line[line.index(after: open)..<close])
            guard let stage = ReleaseCheck.stageLine(text) else {
                return XCTFail("release.sh prints a stage the daemon cannot "
                               + "parse, so dd would never announce it: \(text)")
            }
            XCTAssertFalse(stage.isEmpty, "empty stage in: \(text)")
            stages.append(stage)
        }

        XCTAssertGreaterThanOrEqual(
            stages.count, 8,
            "far fewer stages than expected — either the script was gutted "
            + "or the marker changed and the status poke has gone silent")
    }

    /// The stages the user actually waits through. If one disappears, the
    /// spoken status stops matching what is really happening.
    func testTheLongStagesAreStillNarrated() throws {
        let script = try releaseScript()
        for stage in ["Waiting for CI", "Notarizing", "Publishing GitHub release"] {
            XCTAssertTrue(script.contains("==> \(stage)"),
                          "'\(stage)' is no longer announced — it is one of the "
                          + "slow stages dd's status poke exists to answer with")
        }
    }

    /// The daemon spawns exactly this path with exactly one argument.
    func testDaemonSpawnPathMatchesTheScriptLocation() throws {
        _ = try releaseScript()  // throws if scripts/release.sh moved
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let daemon = try String(
            contentsOf: root.appendingPathComponent("Sources/App/Daemon.swift"),
            encoding: .utf8)
        XCTAssertTrue(daemon.contains("\"scripts/release.sh\""),
                      "the daemon no longer spawns scripts/release.sh — if the "
                      + "script moved, dd is broken")
    }
}
