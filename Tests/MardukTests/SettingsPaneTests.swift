import XCTest
@testable import marduk

/// The System Settings deep link. `:pronunciation` promised the
/// pronunciation editor and delivered the Accessibility LIST — the
/// section one unseen row further in (field 2026-07-23). The navigation
/// itself is AX IPC against System Settings and can't run here; what CAN
/// be pinned is the name table that decides which row gets pressed.
final class SettingsPaneTests: XCTestCase {

    /// Every name the section has worn must still resolve — a user on an
    /// older macOS must not be stranded on the list because the table
    /// only learned macOS 26's wording.
    func testEverySectionNameThisRowHasWornStillMatches() {
        for title in ["Read & Speak Content",   // macOS 26
                      "Spoken Content",         // Ventura … Sequoia
                      "Read and Speak Content"] {
            XCTAssertTrue(
                SettingsPane.matches(title, SettingsPane.readAndSpeakNames),
                "'\(title)' no longer matches — that macOS lands on the list")
        }
    }

    /// The AX tree hands back whatever case the row was drawn in.
    func testMatchingIgnoresCase() {
        XCTAssertTrue(SettingsPane.matches("READ & SPEAK CONTENT",
                                           SettingsPane.readAndSpeakNames))
        XCTAssertTrue(SettingsPane.matches("read & speak content",
                                           SettingsPane.readAndSpeakNames))
    }

    /// The press is invasive — it navigates the user's Settings window —
    /// so the names must not be loose enough to grab a neighbouring row.
    /// Every one of these shares a word with the target.
    func testNeighbouringAccessibilityRowsAreNotMatched() {
        for other in ["VoiceOver", "Zoom", "Display", "Spoken Language",
                      "Speech Recognition", "Live Speech", "Captions",
                      "Voice Control", "Read Aloud", "Speak Selection"] {
            XCTAssertFalse(
                SettingsPane.matches(other, SettingsPane.readAndSpeakNames),
                "'\(other)' would be pressed instead of the real section")
        }
    }

    /// An empty table means "open the pane and stop" — it must never
    /// degrade into matching everything.
    func testAnEmptyNameTableMatchesNothing() {
        XCTAssertFalse(SettingsPane.matches("Read & Speak Content", []))
        XCTAssertFalse(SettingsPane.matches("", []))
    }
}
