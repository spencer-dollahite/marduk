import XCTest
@testable import marduk

/// Two more files that measured 0% executed.
final class SentinelAndEarconTests: XCTestCase {

    // MARK: - DialogSentinel: what gets announced

    private func announce(level: DialogSentinel.Level = .all,
                          isSheet: Bool = false,
                          subrole: String = "AXDialog",
                          title: String = "Allow access?",
                          suppressed: Bool = false) -> String? {
        DialogSentinel.announcement(level: level, isSheet: isSheet,
                                    subrole: subrole, title: title,
                                    appName: "Finder", suppressed: suppressed)
    }

    /// THE shipped regression: Qt apps (Packet Tracer) mass-produce
    /// untitled windows wearing the AXDialog subrole, and every launch
    /// false-alarmed "a dialog needs attention".
    func testUntitledAppDialogsStaySilent() {
        XCTAssertNil(announce(title: ""))
        XCTAssertNil(announce(title: "   \n "), "whitespace is not a title")
    }

    /// A SHEET is structurally real, so it announces even untitled — the
    /// asymmetry that makes the Qt filter safe.
    func testUntitledSheetsStillAnnounce() {
        XCTAssertEqual(announce(isSheet: true, subrole: "", title: ""),
                       "A sheet in Finder needs attention.")
    }

    func testTitledDialogsAndSheetsNameTheirTitle() {
        XCTAssertEqual(announce(), "A dialog in Finder: Allow access?.")
        XCTAssertEqual(announce(isSheet: true, subrole: "", title: "Save changes?"),
                       "A sheet in Finder: Save changes?.")
    }

    /// Standard windows and floating panels — including Marduk's own
    /// palette — must never announce, or opening anything narrates.
    func testOrdinaryWindowsNeverAnnounce() {
        XCTAssertNil(announce(subrole: "AXStandardWindow"))
        XCTAssertNil(announce(subrole: "AXFloatingWindow"))
        XCTAssertNil(announce(subrole: ""))
    }

    func testSystemDialogsAnnounceLikeDialogs() {
        XCTAssertEqual(announce(subrole: "AXSystemDialog", title: "Password"),
                       "A dialog in Finder: Password.")
    }

    /// `:config dialogs system` keeps only the central OS prompts — app
    /// sheets go quiet, which is the whole point of the level.
    func testSystemLevelSilencesAppSheetsAndDialogs() {
        XCTAssertNil(announce(level: .system))
        XCTAssertNil(announce(level: .system, isSheet: true, subrole: "", title: "x"))
        XCTAssertNil(announce(level: .off))
        XCTAssertNil(announce(level: .off, isSheet: true, subrole: "", title: "x"))
    }

    /// Marduk opens sheets itself (the go-to-page gesture) — announcing
    /// our own navigation would be noise.
    func testOurOwnSheetsAreSuppressed() {
        XCTAssertNil(announce(isSheet: true, subrole: "", title: "Go to Page",
                              suppressed: true))
    }

    // MARK: - DialogSentinel: dedup

    /// window-created and sheet-created can fire together, and some apps
    /// re-post on focus cycling.
    func testIdenticalAnnouncementsCollapseWithinTheWindow() {
        let now = Date()
        XCTAssertFalse(DialogSentinel.shouldEmit("A dialog in Finder: x.",
                                                 lastMessage: "A dialog in Finder: x.",
                                                 lastAt: now, now: now))
        XCTAssertTrue(DialogSentinel.shouldEmit(
            "A dialog in Finder: x.", lastMessage: "A dialog in Finder: x.",
            lastAt: now,
            now: now.addingTimeInterval(DialogSentinel.dedupWindow)))
    }

    /// A DIFFERENT dialog must always get through, however fast it follows
    /// — that is the urgent case the sentinel exists for.
    func testADifferentDialogIsNeverSuppressed() {
        let now = Date()
        XCTAssertTrue(DialogSentinel.shouldEmit("A dialog in Finder: two.",
                                                lastMessage: "A dialog in Finder: one.",
                                                lastAt: now, now: now))
        XCTAssertTrue(DialogSentinel.shouldEmit("first ever", lastMessage: nil,
                                                lastAt: .distantPast, now: now))
    }

    // MARK: - Earcon: the only feedback for a mode change

    private func pcmPeak(_ wav: Data) -> Int {
        // 44-byte header, then little-endian 16-bit mono samples
        let body = wav.dropFirst(44)
        var peak = 0
        for i in stride(from: 0, to: body.count - 1, by: 2) {
            let lo = Int(body[body.startIndex + i])
            let hi = Int(body[body.startIndex + i + 1])
            var value = (hi << 8) | lo
            if value > 32767 { value -= 65536 }
            peak = max(peak, abs(value))
        }
        return peak
    }

    /// The six earcons are the ONLY signal for a mode change in NORMAL.
    /// Two that render identically are indistinguishable to a user with
    /// nothing else to go on — and the ladder deliberately encodes its
    /// destination in pitch (riseToNormal ends at 990, riseToReading 784).
    func testEveryEarconRendersDistinctly() {
        let earcons: [(String, Data)] = [
            ("bloopUp", Earcon.wav(frequencies: [500, 800])),
            ("bloopDown", Earcon.wav(frequencies: [800, 500])),
            ("riseToNormal", Earcon.wav(frequencies: [440, 660, 990],
                                        toneDuration: 0.05, gapDuration: 0.0)),
            ("riseToReading", Earcon.wav(frequencies: [440, 660, 784],
                                         toneDuration: 0.05, gapDuration: 0.0)),
            ("fallToInsert", Earcon.wav(frequencies: [990, 660, 440],
                                        toneDuration: 0.05, gapDuration: 0.0)),
            ("error", Earcon.wav(frequencies: [200], toneDuration: 0.11,
                                 gapDuration: 0.0, amplitude: 0.6,
                                 square: true, fadeDuration: 0.0015)),
        ]
        for (i, a) in earcons.enumerated() {
            for b in earcons.dropFirst(i + 1) {
                XCTAssertNotEqual(a.1, b.1,
                                  "\(a.0) and \(b.0) render identically")
            }
        }
    }

    /// The middle rung must be audibly LOWER than the top one, or the
    /// ladder stops telling the user which level they reached.
    func testTheTwoClimbDestinationsDiffer() {
        XCTAssertNotEqual(
            Earcon.wav(frequencies: [440, 660, 990], toneDuration: 0.05,
                       gapDuration: 0.0),
            Earcon.wav(frequencies: [440, 660, 784], toneDuration: 0.05,
                       gapDuration: 0.0))
    }

    /// A well-formed 44-byte RIFF header, or AVAudioPlayer rejects it and
    /// the user gets silence where feedback should be.
    func testWavHeaderIsWellFormed() throws {
        let wav = Earcon.wav(frequencies: [440])
        XCTAssertGreaterThan(wav.count, 44)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: wav[12..<16], as: UTF8.self), "fmt ")
        XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")
        // RIFF size counts everything after the first 8 bytes
        let riffSize = wav[4..<8].reversed().reduce(0) { $0 << 8 | UInt32($1) }
        XCTAssertEqual(Int(riffSize), wav.count - 8)
    }

    /// `Int16(_:)` TRAPS on overflow, so an amplitude or envelope change
    /// would crash the daemon at the exact moment it played an error beep.
    func testLoudEarconsClampInsteadOfTrapping() {
        // Reaching this line at all proves it didn't trap. What the numbers
        // then prove is that it SATURATED rather than wrapping: a wrap
        // would fold peaks back toward zero and turn the beep to mush.
        // 32768 is legitimate — it is |Int16.min|.
        let hot = Earcon.wav(frequencies: [440], amplitude: 4.0, square: true)
        XCTAssertLessThanOrEqual(pcmPeak(hot), 32768)
        XCTAssertGreaterThanOrEqual(pcmPeak(hot), 32767,
                                    "an over-driven earcon must saturate, not wrap")
    }

    /// The shipped amplitudes leave headroom — no earcon is riding the rail.
    func testShippedAmplitudesStayBelowClipping() {
        XCTAssertLessThan(pcmPeak(Earcon.wav(frequencies: [440])), 32767)
        XCTAssertLessThan(
            pcmPeak(Earcon.wav(frequencies: [200], toneDuration: 0.11,
                               gapDuration: 0.0, amplitude: 0.6,
                               square: true, fadeDuration: 0.0015)), 32767)
    }

    /// A degenerate duration must produce a header-only file rather than
    /// trapping on a zero-length buffer.
    func testZeroLengthToneIsSafe() {
        let empty = Earcon.wav(frequencies: [440], toneDuration: 0)
        XCTAssertEqual(empty.count, 44, "header only, no samples")
    }
}
