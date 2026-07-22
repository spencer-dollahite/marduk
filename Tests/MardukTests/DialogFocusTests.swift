import XCTest
@testable import marduk

/// The dialogfocus consent decision table: focusing an announced dialog
/// is input-invasive, so every consequential transition lives in pure
/// logic and gets pinned here — the question wording (full pitch once
/// ever, terse after, zoom-synergy line only when the system setting is
/// known on), the a/o/n/s resolutions, and the one-time zoom pointer.
final class DialogFocusTests: XCTestCase {

    // MARK: - Prompt tail

    func testPromptTailFullOnFirstAsk() {
        let tail = DialogFocus.promptTail(setting: .ask, explained: false,
                                          zoomFollowsFocus: nil)
        XCTAssertNotNil(tail)
        for key in ["a to always focus", "o to focus just this one",
                    "n for not now", "s to stop asking"] {
            XCTAssertTrue(tail!.contains(key), key)
        }
        XCTAssertFalse(tail!.contains("zoom"),
                       "no synergy line when the zoom state is unknown")
    }

    func testPromptTailMentionsZoomSynergyOnlyWhenOn() {
        let on = DialogFocus.promptTail(setting: .ask, explained: false,
                                        zoomFollowsFocus: true)
        XCTAssertTrue(on!.contains("zoom follows keyboard focus"))
        let off = DialogFocus.promptTail(setting: .ask, explained: false,
                                         zoomFollowsFocus: false)
        XCTAssertFalse(off!.contains("zoom"))
    }

    func testPromptTailTerseOnceExplained() {
        for zoom in [true, false, nil] as [Bool?] {
            XCTAssertEqual(DialogFocus.promptTail(setting: .ask, explained: true,
                                                  zoomFollowsFocus: zoom),
                           "Focus? a, o, n, or s.")
        }
    }

    func testPromptTailNilForAlwaysAndOff() {
        for setting in [DialogFocus.Setting.always, .off] {
            for explained in [true, false] {
                XCTAssertNil(DialogFocus.promptTail(setting: setting,
                                                    explained: explained,
                                                    zoomFollowsFocus: true))
            }
        }
    }

    // MARK: - Answer resolution

    func testResolveAnswers() {
        let a = DialogFocus.resolve(answer: "a")!
        XCTAssertEqual(a.newSetting, .always)
        XCTAssertTrue(a.focusNow)
        XCTAssertFalse(a.ack.isEmpty)

        let o = DialogFocus.resolve(answer: "o")!
        XCTAssertNil(o.newSetting)
        XCTAssertTrue(o.focusNow)

        let n = DialogFocus.resolve(answer: "n")!
        XCTAssertNil(n.newSetting)
        XCTAssertFalse(n.focusNow)

        let s = DialogFocus.resolve(answer: "s")!
        XCTAssertEqual(s.newSetting, .off)
        XCTAssertFalse(s.focusNow)
        XCTAssertTrue(s.ack.lowercased().contains("config dialog focus"),
                      "opting out must name the way back")
    }

    func testResolveRejectsOtherKeys() {
        for wrong in ["x", "A", "S", " ", "1"] as [Character] {
            XCTAssertNil(DialogFocus.resolve(answer: wrong), String(wrong))
        }
    }

    // MARK: - Zoom pointer

    func testZoomHintOnlyWhenNotKnownOn() {
        XCTAssertNil(DialogFocus.zoomHint(zoomFollowsFocus: true),
                     "a user who set follow-focus deliberately needs no pointer")
        XCTAssertNotNil(DialogFocus.zoomHint(zoomFollowsFocus: false))
        XCTAssertNotNil(DialogFocus.zoomHint(zoomFollowsFocus: nil))
        XCTAssertTrue(DialogFocus.zoomHint(zoomFollowsFocus: nil)!
            .contains("Zoom, Advanced"))
    }

    // MARK: - Config decode resilience

    func testPartialConfigDecodeSurvivesMissingDialogFocusKey() throws {
        // A keyboard block written before the key existed must decode and
        // default to .ask at the consumption site.
        let json = #"{"ducking":{"duckLevel":5,"rampSteps":15,"rampDurationMs":600,"duckAppleMusic":true,"duckSpotify":true,"useMediaKey":true},"speech":{"rate":0.59},"display":{"invertForApps":[]},"keyboard":{"dialogLevel":"all"}}"#
        let config = try JSONDecoder().decode(MardukConfig.self, from: Data(json.utf8))
        XCTAssertNil(config.keyboard?.dialogFocus)
        let setting = DialogFocus.Setting(
            rawValue: config.keyboard?.dialogFocus ?? "") ?? .ask
        XCTAssertEqual(setting, .ask)
    }
}
