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
    /// says "invert apps" and "p d f dark" where the tables say
    /// "invertapps" and "pdfdark".
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
