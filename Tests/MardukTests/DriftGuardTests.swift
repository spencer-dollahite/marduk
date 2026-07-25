import XCTest
@testable import marduk

/// Guards against DRIFT between tables and the things that describe them.
///
/// Every failure here is silent by construction: a feature that exists but
/// is never spoken is invisible to an audio-only user, and a hand-written
/// list of settings that falls behind the real table tells people that
/// real settings don't exist (which it did — 25 of 28 — until the message
/// was generated from the table).
///
/// These assertions cost nothing and they all pass today.
final class DriftGuardTests: XCTestCase {

    /// Normalize for spoken-vs-written comparison: the spoken reference
    /// says "invert apps" and "prefer dark in preview" where the tables say
    /// "invertapps" and "preferdarkinpreview".
    private func lettersOnly(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - Spoken reference vs the real tables

    /// A command the spoken reference never mentions cannot be discovered
    /// by the users this product exists for.
    func testEveryCommandAppearsInTheSpokenReference() {
        let spoken = lettersOnly(HelpText.commands)
        for name in ColonCommand.commandNames {
            XCTAssertTrue(spoken.contains(lettersOnly(name)),
                          "':\(name)' is never spoken by :commands — it is "
                          + "invisible to an audio-only user")
        }
    }

    /// Same for settings: a new `:config` key that is never spoken may as
    /// well not ship.
    func testEverySettingAppearsInTheSpokenReference() {
        let spoken = lettersOnly(HelpText.commands)
        for setting in ColonCommand.settings {
            XCTAssertTrue(spoken.contains(lettersOnly(setting.key)),
                          "setting '\(setting.key)' is never spoken by "
                          + ":commands — an audio-only user cannot find it")
        }
    }

    // MARK: - The generated settings sentence

    /// The "Unknown setting" message must name EVERY setting. It used to be
    /// written out by hand and drifted to 25 of 28, so mistyping a key
    /// reported that `position`, `dialogfocus`, and `hints` didn't exist.
    func testSpokenSettingListNamesEverySetting() {
        let list = ColonCommand.spokenSettingList()
        for setting in ColonCommand.settings {
            let spoken = ColonCommand.spokenSettingNames[setting.key] ?? setting.key
            XCTAssertTrue(list.contains(spoken),
                          "\(setting.key) is missing from the spoken settings list")
        }
        XCTAssertEqual(list.components(separatedBy: ", ").count,
                       ColonCommand.settings.count)
    }

    /// A spoken override for a key that no longer exists is dead weight
    /// and a sign the table moved without it.
    func testEverySpokenOverrideMatchesARealSetting() {
        let keys = Set(ColonCommand.settings.map(\.key))
        for key in ColonCommand.spokenSettingNames.keys {
            XCTAssertTrue(keys.contains(key),
                          "spoken override '\(key)' has no matching setting")
        }
    }

    // MARK: - The identity trio (TCC grants ride on these agreeing)

    /// launchd label == codesign identifier == CFBundleIdentifier. Marduk's
    /// Accessibility grant survives rebuilds only while these are identical
    /// — CLAUDE.md calls it out, and until now only two of the four legs
    /// were checked anywhere.
    func testIdentityTrioAgrees() {
        XCTAssertEqual(Bundler.bundleID, Codesign.identifier)
        XCTAssertEqual(LaunchAgent.label, Codesign.identifier)
        XCTAssertEqual(Codesign.identifier, "com.marduk.daemon")
    }

    /// The update pipeline's pinned requirement is the only thing standing
    /// between a downloaded DMG and the user's live install. If a rename
    /// ever unpinned it from the identity, verification would still
    /// "succeed" — against nothing in particular.
    func testPinnedRequirementStaysPinned() {
        let requirement = ReleaseUpdater.requirement
        XCTAssertTrue(requirement.contains(Codesign.identifier),
                      "the pinned requirement no longer names our identifier")
        XCTAssertTrue(requirement.contains("anchor apple generic"),
                      "the pinned requirement lost its Apple anchor")
        XCTAssertTrue(requirement.contains("subject.OU"),
                      "the pinned requirement no longer pins a team OU")
    }

    /// The requirement is BARE TEXT; the `-R=` join at each call site is what
    /// tells codesign "this is text, not a file path". A leading `=` on the
    /// constant doubles that marker, and codesign then fails to PARSE the
    /// requirement — exiting non-zero, which reads exactly like a failed
    /// verification. That shipped: every downloaded DMG failed to self-install
    /// while the source channel (which never runs the gate) looked healthy.
    func testRequirementIsBareTextNotSelfMarked() {
        XCTAssertFalse(Codesign.requirement.hasPrefix("="),
                       "the -R= join supplies the inline marker; a second one "
                       + "makes codesign fail to parse the requirement")
        XCTAssertTrue(Codesign.requirement.hasPrefix("identifier "),
                      "requirement text should start with the identifier clause")
    }

    /// Both gate builders must join the marker the same way. They are in
    /// different files and only agree by convention.
    func testEveryRequirementGateSuppliesExactlyOneInlineMarker() {
        let gates = Codesign.verificationGates(bundleAt: "/tmp/Marduk.app")
            + ReleaseUpdater.verificationGates(staging: "/tmp/Marduk.app")
        let requirementArgs = gates.flatMap { $0 }.filter { $0.hasPrefix("-R") }
        XCTAssertFalse(requirementArgs.isEmpty, "no gate tests the requirement any more")
        for arg in requirementArgs {
            XCTAssertEqual(arg, "-R=" + Codesign.requirement,
                           "malformed requirement argument: \(arg)")
            XCTAssertFalse(arg.hasPrefix("-R=="),
                           "doubled inline marker — codesign cannot parse this")
        }
    }

    /// One predicate, used to both PRODUCE and VERIFY. The local signer and
    /// the download verifier must pin the SAME requirement: if they drift,
    /// a locally assembled bundle can stop satisfying what TCC stored while
    /// both paths still report success — and the user pays for it by
    /// re-adding Marduk under Accessibility after every update.
    func testSignerAndDownloadVerifierPinOneRequirement() {
        XCTAssertEqual(ReleaseUpdater.requirement, Codesign.requirement)
    }

    /// The LOCAL sign gates must not assert notarization. A developer build
    /// is signed but never notarized, so an spctl gate would fail on every
    /// machine and the warning would become noise everyone learns to ignore
    /// — which is how the silent-signing failure survived this long.
    func testLocalSignGatesCheckTheRequirementButNotNotarization() {
        let gates = Codesign.verificationGates(bundleAt: "/tmp/Marduk.app")
        XCTAssertFalse(gates.contains { $0.contains("/usr/sbin/spctl") },
                       "a local build is not notarized — spctl would always fail")
        XCTAssertTrue(gates.contains { $0.contains("-R=" + Codesign.requirement) },
                      "the local sign path no longer verifies against the pinned requirement")
        XCTAssertTrue(gates.allSatisfy { $0.last == "/tmp/Marduk.app" },
                      "a gate is not checking the path it was handed")
    }

    /// `isNewer` compares against `Marduk.version`. An unparseable version
    /// makes it answer false for EVERYTHING — silently disabling
    /// self-update for every release-channel user, with no error anywhere.
    func testShippedVersionParsesAsSemver() {
        XCTAssertNotNil(ReleaseCheck.components(Marduk.version),
                        "Marduk.version '\(Marduk.version)' is not semver — "
                        + "self-update would silently stop working")
        XCTAssertTrue(ReleaseCheck.isNewer("999.0.0", than: Marduk.version))
        XCTAssertFalse(ReleaseCheck.isNewer(Marduk.version, than: Marduk.version))
    }

    // MARK: - Question prompts vs the keys actually armed

    /// The welcome ends on a question and the daemon arms t/p/s on its
    /// completion. If the wording stops asking, the capture still arms and
    /// silently eats the user's next three keys.
    func testWelcomeEndsOnItsQuestion() {
        XCTAssertTrue(HelpText.welcome.hasSuffix("Press t, p, or s."),
                      "the welcome no longer ends on the t/p/s question the "
                      + "daemon arms in its completion")
    }

    /// Tips are spoken as "Tip: " + entry (Daemon), so an entry that
    /// repeats the prefix stutters.
    func testTipsAreUsableAndDistinct() {
        XCTAssertFalse(HelpText.tips.isEmpty)
        XCTAssertEqual(Set(HelpText.tips).count, HelpText.tips.count,
                       "duplicate tips")
        for tip in HelpText.tips {
            XCTAssertFalse(tip.isEmpty)
            XCTAssertFalse(tip.hasPrefix("Tip:"),
                           "tips are already prefixed with 'Tip: ' when spoken")
        }
    }
}
