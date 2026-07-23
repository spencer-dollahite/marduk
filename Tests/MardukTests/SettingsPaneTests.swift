import XCTest
import AppKit
import ApplicationServices
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

    // MARK: - The press policy

    /// The named element earned its press by carrying the name.
    func testTheNamedElementIsPressedWhateverItsRole() {
        for role in ["AXStaticText", "AXButton", "AXCell", "AXUnknown"] {
            XCTAssertTrue(SettingsPane.mayPress(level: 0, role: role,
                                                actions: [kAXPressAction]))
        }
    }

    /// The label is usually a leaf inside the pressable cell, so the walk
    /// upward has to be allowed — but only through row-shaped containers.
    func testAncestorsMustBeRowShaped() {
        for role in SettingsPane.rowRoles {
            XCTAssertTrue(SettingsPane.mayPress(level: 1, role: role,
                                                actions: [kAXPressAction]),
                          "a \(role) ancestor is how a row is built")
        }
    }

    /// THE containment guarantee: a label buried somewhere unexpected
    /// must never walk up into pressing the window, the list, or the
    /// scroll area — that would navigate the user somewhere arbitrary.
    func testTheWalkCanNeverPressAContainerThatIsNotARow() {
        for role in ["AXWindow", "AXScrollArea", "AXTable", "AXOutline",
                     "AXList", "AXSplitGroup", "AXToolbar", "AXApplication"] {
            XCTAssertFalse(SettingsPane.mayPress(level: 1, role: role,
                                                 actions: [kAXPressAction]),
                           "pressing a \(role) is not navigating a row")
        }
    }

    /// An unreadable role (AX error) is not an invitation to press.
    func testAnAncestorWithNoRoleIsNotPressed() {
        XCTAssertFalse(SettingsPane.mayPress(level: 1, role: nil,
                                             actions: [kAXPressAction]))
    }

    /// AXPress must be advertised — performing an unsupported action is
    /// how a press lands on something that only looked pressable.
    func testNothingIsPressedWithoutTheAXPressAction() {
        XCTAssertFalse(SettingsPane.mayPress(level: 0, role: "AXButton",
                                             actions: []))
        XCTAssertFalse(SettingsPane.mayPress(level: 0, role: "AXButton",
                                             actions: ["AXShowMenu", "AXScrollToVisible"]))
    }

    /// The climb is bounded. Past the limit the answer is no, whatever
    /// the element claims to be.
    func testTheClimbStopsAtTheAncestorLimit() {
        let limit = SettingsPane.ancestorLimit
        XCTAssertTrue(SettingsPane.mayPress(level: limit, role: kAXCellRole,
                                            actions: [kAXPressAction]))
        XCTAssertFalse(SettingsPane.mayPress(level: limit + 1, role: kAXCellRole,
                                            actions: [kAXPressAction]),
                       "the walk escaped its bound")
    }

    // MARK: - The URL itself

    /// The anchor is vestigial — macOS ignores it, which is the whole
    /// reason the AX descent exists — but the PANE has to stay right, or
    /// the descent starts from the wrong window.
    func testTheDeepLinkNamesTheAccessibilityPane() throws {
        let url = try XCTUnwrap(URL(string: SettingsPane.accessibilityPaneURL),
                                "the deep link must be a legal URL")
        XCTAssertEqual(url.scheme, "x-apple.systempreferences")
        XCTAssertTrue(SettingsPane.accessibilityPaneURL
                        .contains("com.apple.preference.universalaccess"),
                      "the link must open Accessibility")
    }

    /// The scheme has to still be REGISTERED — this is the one part of
    /// the deep link a future macOS can silently retire, and the manual
    /// future-macOS probe runs this suite. Skipped where the environment
    /// can't answer, so a headless box reports "unknown", never a false
    /// green or a false red.
    func testTheSystemSettingsSchemeIsRegisteredToSystemSettings() throws {
        let workspace = NSWorkspace.shared
        guard let control = URL(string: "https://example.com"),
              workspace.urlForApplication(toOpen: control) != nil else {
            throw XCTSkip("LaunchServices resolves nothing here — "
                + "no verdict available on this machine")
        }
        let target = try XCTUnwrap(URL(string: SettingsPane.accessibilityPaneURL))
        let handler = try XCTUnwrap(
            workspace.urlForApplication(toOpen: target),
            "no app claims x-apple.systempreferences — the deep link is dead "
                + "on this macOS and both :pronunciation and :typing go nowhere")
        XCTAssertEqual(Bundle(url: handler)?.bundleIdentifier,
                       SettingsPane.bundleID,
                       "the scheme resolves somewhere other than System Settings")
    }

    // MARK: - Wiring

    /// What `:pronunciation` and `:typing` actually hand LaunchServices.
    func testOpeningReadAndSpeakContentLaunchesTheAccessibilityPane() {
        SettingsPane.deadline = 0.1   // the descent this spawns finds nothing
        SettingsPane.pollInterval = 0.05
        var launched: [String] = []
        SettingsPane.launch = { launched.append($0) }
        SettingsPane.openReadAndSpeakContent()
        XCTAssertEqual(launched, [SettingsPane.accessibilityPaneURL])
    }

    /// The descent polls for seconds. It must never do that on the
    /// caller's thread — `:pronunciation` is dispatched from the daemon's
    /// main queue, which also drives the event tap (a >4s main-thread
    /// stall is what disables the tap and half-kills the keyboard).
    func testOpenReturnsImmediatelyWhileTheDescentRunsOffThread() {
        SettingsPane.deadline = 0.2
        SettingsPane.pollInterval = 0.05
        SettingsPane.launch = { _ in }
        let start = Date()
        SettingsPane.open("x-apple.systempreferences:test",
                          thenSelect: ["a row that is not there"])
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1,
                          "open() blocked its caller on the AX descent")
    }

    /// Priming the capture BEFORE any case swaps the launcher — a
    /// static let is lazy, so a first touch inside tearDown would
    /// "restore" the test double forever after.
    override func setUp() {
        super.setUp()
        _ = Self.realLauncher
    }

    override func tearDown() {
        SettingsPane.launch = Self.realLauncher
        SettingsPane.deadline = 6
        SettingsPane.pollInterval = 0.3
        super.tearDown()
    }

    /// Captured before any case swaps it in, so tearDown restores the
    /// real thing rather than whatever the previous case installed.
    private static let realLauncher = SettingsPane.launch
}
