import XCTest
@testable import marduk

/// Real-user journeys, composed from the pure cores.
///
/// Every other test file exercises ONE core in isolation. Every bug that
/// reached the user in the field lived between two of them — a windowed
/// read whose stop was mistaken for a natural end, a `gg` that resolved in
/// window coordinates, an inverter whose two switches were gated
/// asymmetrically. These walk sequences instead of asserting points.
///
/// The driver below is deliberately thin: it holds the state
/// `SpeechEngine` holds and applies the same rules, so a divergence between
/// this and the engine shows up as a journey that no longer matches what
/// the user reports.
final class JourneyTests: XCTestCase {

    // MARK: - A minimal read session

    /// Mirrors `SpeechEngine`'s reading state: the window, where the voice
    /// is, and the jumplist. Page numbers are 1-based and GLOBAL, matching
    /// `JumpList.Position` and `ModePolicy.documentEdge`.
    private struct Session {
        let full: PagedText?          // nil on a plain read
        var window: PagedText
        var windowFirst = 0           // global index of the window's first page
        var position = 0              // UTF-16 offset into the window
        var jumps = JumpList()
        let session = 1

        var isPaged: Bool { full != nil }
        var globalPage: Int { windowFirst + window.pageIndex(at: position) + 1 }

        var here: JumpList.Position {
            isPaged ? .paged(page: globalPage, windowFirst: windowFirst,
                             offset: position)
                    : .plain(offset: position)
        }

        /// Load the window containing a global page and park at its start —
        /// what `speakPage`/`loadPageWindow` do together.
        mutating func goToPage(_ page: Int) {
            guard let full else { return }
            let target = max(0, min(page - 1, full.pageCount - 1))
            let local = target - windowFirst
            if window.pageStarts.indices.contains(local) {
                position = window.pageStarts[local]
            } else {
                let (first, rebuilt) = full.window(startingAt: target)
                windowFirst = first
                window = rebuilt
                position = rebuilt.pageStarts[target - first]
            }
        }

        /// A jump that vim would record: capture where we came FROM, move,
        /// and only then push — the `recordingJump` rule.
        mutating func jump(recording: Bool = true, _ move: (inout Session) -> Void) {
            let origin = here
            move(&self)
            if recording { jumps.record(origin, session: session) }
        }

        mutating func restore(_ target: JumpList.Position) {
            switch target {
            case .plain(let offset):
                position = offset
            case .paged(let page, let windowFirst, let offset):
                if windowFirst == self.windowFirst {
                    position = offset          // same window, same string
                } else {
                    goToPage(page)             // page-granular across windows
                }
            }
        }
    }

    private func terminalScrollback(pages: Int) -> String {
        // Paragraph-shaped so the chunker has blank-line cut points
        (0..<pages).map { "line \($0) of the scrollback\n\nbody text here" }
            .joined(separator: "\n\n")
    }

    // MARK: - Journey 1: the 2026-07-22 field bug, replayed

    /// The user opened a Terminal scrollback at their pointer (mid-buffer),
    /// pressed `50%`, then `gg`, and could never get back. This walks the
    /// exact sequence and asserts Ctrl+O returns them.
    func testTerminalScrollbackJumpAndReturn() throws {
        let text = terminalScrollback(pages: 400)
        let ns = text as NSString
        let pointerStart = ns.length / 2          // R started under the pointer
        let (full, startPage) = PagedText.chunking(text, from: pointerStart)
        XCTAssertGreaterThan(full.pageCount, 20, "fixture must actually window")

        let (first, window) = full.window(startingAt: startPage - 1)
        var s = Session(full: full, window: window)
        s.windowFirst = first
        s.position = window.pageStarts[startPage - 1 - first]
        let began = s.globalPage
        XCTAssertGreaterThan(began, 1, "the read must start mid-document")

        // 50% — a vim jump, page-granular on a paged read
        s.jump { s in
            let target = full.pageIndex(at: 50 * full.utf16Length / 100)
            s.goToPage(target + 1)
        }
        let halfway = s.globalPage

        // gg — BOTH edges are pages on a paged read (the second field bug)
        s.jump { s in
            guard case .page(let n) = ModePolicy.documentEdge(
                forward: false, isPaged: s.isPaged, pageCount: full.pageCount)
            else { return XCTFail("gg fell through to a text offset") }
            s.goToPage(n)
        }
        XCTAssertEqual(s.globalPage, 1, "gg must reach the true top")

        // Ctrl+O walks back: first to where gg was pressed, then to the start
        let backOnce = try XCTUnwrap(s.jumps.back(from: s.here))
        s.restore(backOnce)
        XCTAssertEqual(s.globalPage, halfway, "first Ctrl+O returns to the 50% spot")

        let backTwice = try XCTUnwrap(s.jumps.back(from: s.here))
        s.restore(backTwice)
        XCTAssertEqual(s.globalPage, began,
                       "second Ctrl+O returns to where the read began — the "
                       + "trip the user could not make")

        // …and Ctrl+I retraces it
        let forward = try XCTUnwrap(s.jumps.forward())
        s.restore(forward)
        XCTAssertEqual(s.globalPage, halfway)
    }

    /// Nothing older must buzz rather than moving somewhere arbitrary.
    func testCtrlOOnAFreshReadHasNowhereToGo() {
        let text = terminalScrollback(pages: 100)
        let (full, startPage) = PagedText.chunking(text, from: 0)
        let (first, window) = full.window(startingAt: startPage - 1)
        var s = Session(full: full, window: window)
        s.windowFirst = first
        XCTAssertNil(s.jumps.back(from: s.here))
    }

    // MARK: - Journey 2: the plain/windowed seam

    /// Every reading bug this week lived on this seam. The same gestures
    /// over a small document and a huge one must agree on everything except
    /// the documented difference (pages exist, so edges are pages).
    func testPlainAndWindowedReadsAgreeOnTheEdges() {
        let small = "one\n\ntwo\n\nthree"
        XCTAssertFalse(PagedText.exceedsWindow((small as NSString).length))
        XCTAssertEqual(
            ModePolicy.documentEdge(forward: false, isPaged: false, pageCount: 0),
            .textOffset)

        let big = terminalScrollback(pages: 400)
        XCTAssertTrue(PagedText.exceedsWindow((big as NSString).length))
        let (full, _) = PagedText.chunking(big, from: 0)
        XCTAssertEqual(
            ModePolicy.documentEdge(forward: false, isPaged: true,
                                    pageCount: full.pageCount),
            .page(1))
        XCTAssertEqual(
            ModePolicy.documentEdge(forward: true, isPaged: true,
                                    pageCount: full.pageCount),
            .page(full.pageCount))
    }

    /// A windowed read must reach its LAST page — the whole point of
    /// window continuation, and what the escape bug interrupted.
    func testEveryPageOfAWindowedReadIsReachable() {
        let (full, _) = PagedText.chunking(terminalScrollback(pages: 300), from: 0)
        let (first, window) = full.window(startingAt: 0)
        var s = Session(full: full, window: window)
        s.windowFirst = first
        for page in [1, full.pageCount / 2, full.pageCount] {
            s.goToPage(page)
            XCTAssertEqual(s.globalPage, page, "page \(page) was unreachable")
        }
    }

    // MARK: - Journey 3: typing rescue → INSERT → reclaim the read

    /// The user is listening to a read, types "sun" out of habit, and the
    /// rescue puts them in INSERT. They hold Escape to get back.
    func testTypingDuringAReadRescuesThenGivesTheReadBack() {
        // s and u are command letters; n is not (Firefox isn't frontmost),
        // so the burst resolves as typing on the third key.
        var buffer: [Int64] = []
        let word: [Int64] = [1, 32, 45]     // s, u, n
        var verdict = BurstPolicy.Verdict.passThrough
        for key in word {
            verdict = BurstPolicy.classify(buffer: buffer, keycode: key,
                                           isLetter: true, isAutorepeat: false,
                                           firefoxFrontmost: false,
                                           releaseAvailable: false)
            switch verdict {
            case .startBuffer, .append: buffer.append(key)
            default: break
            }
        }
        XCTAssertEqual(verdict, .declareTyping, "'sun' must rescue as typing")

        // Rescue lands in INSERT while the read keeps playing.
        let hold = ModePolicy.escapeHoldDestination(
            mode: .insert, readActive: true, readMotionsEnabled: true, enabled: true)
        XCTAssertEqual(hold, .reclaimReading)
        // …and leaving INSERT must not be undone when the read ends.
        XCTAssertEqual(ModePolicy.underlyingMode(after: hold, current: .insert),
                       .normal)
        // The read still owns the keyboard.
        XCTAssertEqual(
            ModePolicy.escapeTap(mode: .normal, readingCapture: true,
                                 readActive: true, readPaused: false),
            .togglePause)
    }

    /// The counterpart: deliberate commands must NOT rescue.
    func testDeliberateCommandPairsStayCommands() {
        let verdict = BurstPolicy.classify(buffer: [1], keycode: 15,
                                           isLetter: true, isAutorepeat: false,
                                           firefoxFrontmost: false,
                                           releaseAvailable: false)
        XCTAssertEqual(verdict, .append, "'s' then 'r' are two commands")
    }

    /// `dd` cannot exist on a stranger's Homebrew install.
    func testTheReleaseGestureIsInvisibleOffASourceInstall() {
        XCTAssertEqual(
            BurstPolicy.classify(buffer: [2], keycode: 2, isLetter: true,
                                 isAutorepeat: false, firefoxFrontmost: false,
                                 releaseAvailable: false),
            .declareTyping, "double-d must be typing on a release install")
        XCTAssertEqual(
            ReleaseFlow.onCutReleaseKey(hasProjectDir: false, inFlight: false,
                                        stage: "starting"),
            .refuseNotSource, "and the daemon refuses even if it were reached")
    }

    // MARK: - Journey 4: a low-vision inversion session

    /// Pages comes forward and goes dark; the user leaves; they quit. The
    /// sequence that blinded them three times in one day.
    func testPagesInversionSessionInvertsOnceAndHandsItBack() {
        let config = MardukConfig.DisplayConfig()
        XCTAssertFalse(
            InversionPolicy.isActive(invertEnabled: config.invertEnabled ?? false,
                                     autoInvert: config.autoInvert ?? false),
            "inversion is opt-in and off by default")

        let active = InversionPolicy.isActive(invertEnabled: true, autoInvert: false)
        // Pages front, display normal → invert
        XCTAssertEqual(
            InversionPolicy.resolve(wanted: true, believed: false, actual: false,
                                    active: active, sinceLastToggle: 99, lockout: 1.5),
            .fire(effective: false))
        // Immediately again — the lockout holds
        XCTAssertEqual(
            InversionPolicy.resolve(wanted: true, believed: true, actual: true,
                                    active: active, sinceLastToggle: 0.1, lockout: 1.5),
            .lockedOut)
        // Still front later — already there, nothing to do
        XCTAssertEqual(
            InversionPolicy.resolve(wanted: true, believed: true, actual: true,
                                    active: active, sinceLastToggle: 99, lockout: 1.5),
            .noChange(effective: true))
        // User leaves → hand it back
        XCTAssertEqual(
            InversionPolicy.resolve(wanted: false, believed: true, actual: true,
                                    active: active, sinceLastToggle: 99, lockout: 1.5),
            .fire(effective: true))
        // Quitting reverts only what we own
        XCTAssertTrue(InversionPolicy.shouldRevertOnExit(believed: true, actual: true,
                                                         owned: true))
        XCTAssertFalse(InversionPolicy.shouldRevertOnExit(believed: true, actual: true,
                                                          owned: false))
    }

    /// The incident itself: belief said inverted, the display was normal,
    /// and the "revert" INVERTED a dark screen.
    func testAStaleBeliefCanNeverFireAToggle() {
        let active = InversionPolicy.isActive(invertEnabled: true, autoInvert: true)
        XCTAssertEqual(
            InversionPolicy.resolve(wanted: false, believed: true, actual: false,
                                    active: active, sinceLastToggle: 99, lockout: 1.5),
            .noChange(effective: false))
    }

    // MARK: - Journey 5: typing a `:` command with realistic pauses

    /// Auto-accept fires on a pause. Typing `config rate 230` must produce
    /// exactly one execution, never an early one — and `se` must never
    /// resolve to `security` mid-word.
    func testTypingAConfigCommandResolvesExactlyOnce() {
        let full = "config rate 230"
        var executions: [String] = []
        for end in 1...full.count {
            let prefix = String(full.prefix(end))
            if case .execute(let command) = ColonCommand.autoResolve(prefix) {
                executions.append(command)
            }
        }
        XCTAssertEqual(executions, ["config rate 230"],
                       "a number must wait for Return until it is complete")
    }

    func testSeNeverResolvesToSecurityMidWord() {
        XCTAssertEqual(ColonCommand.autoResolve("se"), .none,
                       "':se rate 230' is vim muscle memory — it must stay "
                       + "ambiguous, not open the security email")
        XCTAssertEqual(ColonCommand.autoResolve("sec"), .execute("security"))
    }

    // MARK: - Journey 6: crash loop → safe mode → the fix can still arrive

    /// Safe mode's entire purpose is that a user who crash-loops can still
    /// press `u` and get the fix. Never asserted end to end before.
    func testSafeModeStillLetsAnUpdateArrive() {
        let original = BootGuard.markerURL
        BootGuard.markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("journey-boot-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: BootGuard.markerURL)
            BootGuard.markerURL = original
        }

        var attempt = 0
        for _ in 0..<BootGuard.safeModeThreshold { attempt = BootGuard.register() }
        XCTAssertEqual(attempt, BootGuard.safeModeThreshold, "safe mode trips")

        // The update train stays alive in safe mode, so a newer release is
        // still installable — and an older one still refused.
        XCTAssertTrue(ReleaseCheck.isNewer("99.0.0", than: Marduk.version))
        XCTAssertFalse(ReleaseCheck.isNewer("0.0.1", than: Marduk.version))
    }

    // MARK: - Journey 7: cutting a release with `dd`

    func testDoubleDCutsAReleaseEndToEnd() {
        XCTAssertEqual(
            ReleaseFlow.onCutReleaseKey(hasProjectDir: true, inFlight: false,
                                        stage: "starting"),
            .askToCut)
        let next = ReleaseCheck.nextVersion(fromTagList: "v0.4.9\nv0.4.10\n")
        XCTAssertEqual(next, "0.4.11")
        XCTAssertEqual(ReleaseFlow.onAnswer("y"), .start)

        // The script's real stage lines drive the spoken status
        var stage = "starting"
        for line in ["==> Syncing with origin",
                     "==> Waiting for CI on the release commit",
                     "==> Notarizing the app (this usually takes a few minutes)"] {
            if let parsed = ReleaseCheck.stageLine(line) { stage = parsed }
        }
        XCTAssertEqual(
            ReleaseFlow.onCutReleaseKey(hasProjectDir: true, inFlight: true,
                                        stage: stage),
            .statusPoke(stage: "Notarizing the app (this usually takes a few minutes)"))

        XCTAssertEqual(
            ReleaseFlow.spoken(ReleaseFlow.outcome(status: 0, timedOut: false,
                                                   version: "0.4.11", stage: stage)),
            "Release 0.4.11 is live.")
    }

    /// Anything but `y` must decline — a release reaches strangers.
    func testAnyOtherKeyDeclinesTheRelease() {
        for key: Character in ["n", "Y", "d", " "] {
            XCTAssertEqual(ReleaseFlow.onAnswer(key), .decline)
        }
    }
}
