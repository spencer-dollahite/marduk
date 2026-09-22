import XCTest
@testable import marduk

/// The read that never started.
///
/// Field reports 2026-08-06 and 2026-08-08, same words both times: pressing
/// the read button sometimes "starts and then quickly stops without reading
/// anything", and the very same selection reads fine on the next press. In
/// the log it has one exact shape, dozens of times:
///
///     [keyboard] speak selection (150 chars)
///     [keyboard] → READING
///     [speech] didFinish fired          <- no didStart, nothing spoken
///     [keyboard] read ended → insert
///
/// The cause is the stop-then-speak race: `stopSpeaking(at:)` empties the
/// synthesizer's QUEUE asynchronously, every speaking path calls `stop()`
/// and then enqueues in the same turn, and a flush that lands after the
/// enqueue takes the brand-new utterance with it.
///
/// These tests pin both halves of the answer — the guard that stops the
/// loss happening (`Handoff`) and the recovery for one that happened
/// anyway (`finishVerdict`). Written against the pure model because the
/// failure lives in a synthesizer we cannot instrument: no hosted runner
/// can reproduce an AVSpeechSynthesizer flush race, so the RULES are what
/// get pinned, exactly as ModePolicy pins the modal ladder.
final class SpeechHealthTests: XCTestCase {

    // MARK: - Prevention: which instance is safe to speak into

    /// The steady state must cost nothing. A read that ends cleanly and is
    /// followed, later, by another read has no hazard at all — if this
    /// went the other way, every single read would allocate a synthesizer
    /// for no reason.
    func testAQuietInstanceAfterACleanReadIsSpokenIntoDirectly() {
        var handoff = SpeechHealth.Handoff()
        handoff.handedOver()
        handoff.speechStarted()
        handoff.utteranceEnded()
        XCTAssertFalse(handoff.needsFreshSynthesizer(isSpeaking: false,
                                                     isPaused: false),
                       "a settled synthesizer was needlessly thrown away")
    }

    /// THE BUG. A read is playing and the user presses read again: `stop()`
    /// issues a flush, and the new utterance is enqueued in the same turn.
    /// Before the fix this went straight into the same instance and was
    /// sometimes swept up by the flush it raced.
    func testInterruptingASpeakingReadDemandsAFreshInstance() {
        var handoff = SpeechHealth.Handoff()
        handoff.handedOver()
        handoff.speechStarted()      // read A is audible
        handoff.stopIssued()         // stop() before speaking read B
        XCTAssertTrue(handoff.needsFreshSynthesizer(isSpeaking: true,
                                                    isPaused: false),
                      "read B was handed to an instance with a flush in flight")
    }

    /// The field shape, which is subtler than a plain interrupt: read A has
    /// already reported its end and the user presses read again a moment
    /// later, but the instance is still winding down and reports itself
    /// speaking — so `stop()` issues a flush after all, and B is at risk.
    func testAReadPressedRightAfterTheLastOneEndedIsStillAtRisk() {
        var handoff = SpeechHealth.Handoff()
        handoff.handedOver()
        handoff.speechStarted()
        handoff.utteranceEnded()     // didFinish for read A arrived…
        handoff.stopIssued()         // …but stop() still found it "speaking"
        XCTAssertTrue(handoff.needsFreshSynthesizer(isSpeaking: true,
                                                    isPaused: false),
                      "the teardown-lag case is exactly where the field "
                        + "failures cluster")
    }

    /// An utterance still outstanding is enough on its own. The
    /// synthesizer's own `isSpeaking` is a lagging signal and has been seen
    /// to lie in both directions; our own bookkeeping does not.
    func testAnUnresolvedUtteranceIsEnoughEvenIfTheSynthesizerLooksIdle() {
        var handoff = SpeechHealth.Handoff()
        handoff.handedOver()
        XCTAssertTrue(handoff.needsFreshSynthesizer(isSpeaking: false,
                                                    isPaused: false))
    }

    /// The ordering trap, and the reason suspicion is cleared by didStart
    /// rather than by the end callback: the flush and the callback are two
    /// different events with no guaranteed order. Clearing on the callback
    /// would declare the instance clean in precisely the interleaving the
    /// guard exists to catch.
    func testTheStoppedUtterancesEndCallbackDoesNotClearTheSuspicion() {
        var handoff = SpeechHealth.Handoff()
        handoff.handedOver()
        handoff.speechStarted()
        handoff.stopIssued()
        handoff.utteranceEnded()     // the cancelled utterance reports back
        XCTAssertTrue(handoff.needsFreshSynthesizer(isSpeaking: false,
                                                    isPaused: false),
                      "an end callback is not proof the queue flush landed")
    }

    /// What DOES clear it: the instance starting an utterance. That is the
    /// only observation that proves a pending flush did not eat it.
    func testStartingSpeechProvesTheInstanceIsHealthyAgain() {
        var handoff = SpeechHealth.Handoff()
        handoff.stopIssued()
        handoff.handedOver()
        handoff.speechStarted()
        handoff.utteranceEnded()
        XCTAssertFalse(handoff.needsFreshSynthesizer(isSpeaking: false,
                                                     isPaused: false))
    }

    /// A paused synthesizer is the other wedge (a stop landing on a paused
    /// instance can leave it queueing silently forever) — it must never be
    /// spoken into either.
    func testAPausedInstanceIsNeverSpokenInto() {
        var handoff = SpeechHealth.Handoff()
        handoff.handedOver()
        handoff.speechStarted()
        handoff.utteranceEnded()
        XCTAssertTrue(handoff.needsFreshSynthesizer(isSpeaking: false,
                                                    isPaused: true))
    }

    /// A brand-new instance has no queue and nothing in flight — that is
    /// the whole reason it is the answer.
    func testAFreshInstanceIsClean() {
        var handoff = SpeechHealth.Handoff()
        handoff.stopIssued()
        handoff.handedOver()
        handoff.freshInstance()
        XCTAssertFalse(handoff.needsFreshSynthesizer(isSpeaking: false,
                                                     isPaused: false))
        XCTAssertEqual(handoff, SpeechHealth.Handoff())
    }

    /// The rebuild reason is logged, so a field log explains its own
    /// allocations. Reasons and ids only — never content.
    func testTheRebuildReasonNamesEveryContributingSignal() {
        var handoff = SpeechHealth.Handoff()
        handoff.stopIssued()
        handoff.handedOver()
        let reason = SpeechHealth.freshReason(handoff, isSpeaking: true,
                                              isPaused: false)
        XCTAssertTrue(reason.contains("stop flush unconfirmed"))
        XCTAssertTrue(reason.contains("previous utterance unresolved"))
        XCTAssertTrue(reason.contains("still speaking"))
        XCTAssertFalse(reason.contains("paused"))
    }

    // MARK: - The silent window before the first syllable

    private func silentStartup(speaking: Bool = true, paused: Bool = false,
                               heard: Bool = false,
                               since: TimeInterval? = 0.4) -> Bool {
        SpeechHealth.isSilentStartup(isSpeaking: speaking, isPaused: paused,
                                     heardAudio: heard,
                                     sinceHandover: since)
    }

    /// The field failure of 2026-08-09: the read had been handed over
    /// 0.15s earlier and had said nothing, yet `isSpeaking` was true — so
    /// the read button's three-way called it "audibly speaking" and
    /// stopped it.
    func testAJustHandedOverReadIsNotAudiblySpeaking() {
        XCTAssertTrue(silentStartup(since: 0.15))
        XCTAssertTrue(silentStartup(since: 0.56),
                      "a cold synthesizer can take half a second to speak")
    }

    /// Evidence of speech ends it — from there the press means what it
    /// always meant. Past the bounce floor, that is: the window's first
    /// quarter-second belongs to the switch, whatever the synthesizer
    /// claims (see the next test).
    func testAudioEndsTheSilentWindow() {
        XCTAssertFalse(silentStartup(heard: true, since: 0.4))
        XCTAssertFalse(silentStartup(heard: true, since: 1.0))
    }

    /// THE FOURTH CAUSE (field 2026-09-22, macOS 27). didStart now fires
    /// ~10ms after handover, before any sound, and the duplicate press
    /// that follows the button's real press 0.02–0.2s later found the
    /// guard already stood down: 62 presses absorbed on macOS 26, 4 on 27,
    /// the rest killing the read they had asked for. Two answers, both
    /// pinned here: the evidence the guard accepts is the WORD BOUNDARY
    /// (`heardAudio`, which the engine sets from nothing else — see the
    /// drift guard below), and inside `bounceFloor` no evidence counts at
    /// all — nobody asks for a read and silences it a quarter-second on.
    func testABouncedPressIsIgnoredEvenWhenTheSynthesizerClaimsAudio() {
        XCTAssertTrue(silentStartup(heard: true, since: 0.02),
                      "the 27 shape: 'audible' at 10ms, bounce at 20ms")
        XCTAssertTrue(silentStartup(heard: true, since: 0.2))
        XCTAssertTrue(silentStartup(heard: false, since: 0.2))
        XCTAssertFalse(silentStartup(heard: true, since: SpeechHealth.bounceFloor),
                       "the floor is a floor — a press at it is a decision")
        XCTAssertTrue(SpeechHealth.bounceFloor < SpeechHealth.startupGrace,
                      "the bounce floor is the near edge of the silent "
                        + "window, never past it")
    }

    /// If boundaries lapse, the cost is bounded and known: the button is
    /// a no-op for `startupGrace` and works again after, so a wedged read
    /// can still be silenced (and Escape never consults this at all).
    func testWithoutABoundaryTheGuardHoldsOnlyForTheGraceWindow() {
        XCTAssertTrue(silentStartup(heard: false, since: 1.0))
        XCTAssertFalse(silentStartup(heard: false, since: SpeechHealth.startupGrace))
    }

    /// A PAUSED read has spoken. Its press means "stop this and read the
    /// new selection", and swallowing it would break chained reads —
    /// which is the failure the paused branch exists to fix.
    func testAPausedReadIsNotStartingSilently() {
        XCTAssertFalse(silentStartup(paused: true))
    }

    /// Idle is idle: with nothing queued the press reads the selection.
    func testAnIdleSynthesizerIsNotStartingSilently() {
        XCTAssertFalse(silentStartup(speaking: false))
        XCTAssertFalse(silentStartup(since: nil))
    }

    /// The window is BOUNDED. Past the grace period something is wedged
    /// rather than slow, and a keypress that can never stop anything is
    /// its own failure — the user must be able to silence a stuck read.
    func testTheSilentWindowExpires() {
        XCTAssertFalse(silentStartup(since: SpeechHealth.startupGrace))
        XCTAssertFalse(silentStartup(since: 4.0))
    }

    /// Why the guard had to live here and not in the recovery ladder: a
    /// stop landing in the silent window makes the finish that follows
    /// indistinguishable from a user's Escape, and `.stopped` is never
    /// re-spoken. Prevention is the only move.
    func testAStopInTheSilentWindowLooksExactlyLikeAUserStop() {
        XCTAssertEqual(verdict(stopped: true, elapsed: 0.1), .stopped)
    }

    // MARK: - Recovery: a finish that spoke nothing

    private func verdict(current: Bool = true, spoke: Bool = false,
                         stopped: Bool = false, elapsed: TimeInterval = 0.01,
                         retried: Bool = false,
                         canRespeak: Bool = true) -> SpeechHealth.FinishVerdict {
        SpeechHealth.finishVerdict(isCurrentUtterance: current,
                                   sawEvidenceOfSpeech: spoke,
                                   stopRequested: stopped,
                                   elapsed: elapsed,
                                   alreadyRetried: retried,
                                   canRespeak: canRespeak)
    }

    /// The field failure itself: a finish, milliseconds after handover,
    /// with no evidence anything was spoken and no stop requested.
    func testAFinishWithNothingSpokenIsRetried() {
        XCTAssertEqual(verdict(), .retry)
    }

    /// An ANNOUNCEMENT swallowed the same way is now retried too. It was
    /// not before: the old rule required retained read text, so a dropped
    /// dialog title, stock alert or "Update complete" was simply lost.
    /// Speech is the only output this product has and there is no
    /// scrollback — a message nobody heard is a message nobody got.
    func testASwallowedAnnouncementIsSaidAgainToo() {
        // `canRespeak` is what the engine passes for an announcement now:
        // there is no read text, but the utterance itself is retained and
        // can be re-issued verbatim. The old rule was "read text or
        // nothing", which is this same call with canRespeak forced false —
        // and it gave up.
        XCTAssertEqual(verdict(canRespeak: true), .retry)
        XCTAssertEqual(verdict(canRespeak: false), .giveUp,
                       "the old rule's answer, kept as the contrast")
    }

    /// A real read that actually spoke ends normally. `sawEvidenceOfSpeech`
    /// is set by didStart AND by the first word boundary, so real speech
    /// marks itself twice over.
    func testAFinishAfterRealSpeechIsJustAFinish() {
        XCTAssertEqual(verdict(spoke: true), .spoken)
        XCTAssertEqual(verdict(spoke: true, elapsed: 0.001), .spoken,
                       "evidence of audio outranks how fast the finish came")
    }

    /// Escape stopping a read before it started arrives in the SAME shape
    /// as a phantom. Retrying there would fight the user's stop — the one
    /// thing worse than a read that does not start is one that will not.
    func testAUserStopBeforeSpeechStartedIsNeverRetried() {
        XCTAssertEqual(verdict(stopped: true), .stopped)
    }

    /// Evidence outranks the stop flag: a stopped read that HAD spoken is
    /// an ordinary end, not a swallowed one.
    func testEvidenceOutranksTheStopFlag() {
        XCTAssertEqual(verdict(spoke: true, stopped: true), .spoken)
    }

    /// Stale callbacks — the corpse of a read already replaced — say
    /// nothing about the health of the one now in flight, and must never
    /// trigger a retry that would clobber it.
    func testAStaleUtterancesFinishIsIgnored() {
        XCTAssertEqual(verdict(current: false), .stale)
        XCTAssertEqual(verdict(current: false, elapsed: 0.001), .stale)
    }

    /// The safety side of the trade. Delegate delivery has been seen to
    /// lapse WHILE AUDIBLE, so "no evidence" is not proof of silence — but
    /// a finish that took real time cannot have spoken nothing. Repeating
    /// a read the user already heard is a worse bug than the one being
    /// fixed, so a slow finish is never retried, only logged.
    func testASlowFinishIsNeverRepeated() {
        XCTAssertEqual(verdict(elapsed: SpeechHealth.phantomWindow), .giveUp)
        XCTAssertEqual(verdict(elapsed: 3.0), .giveUp)
        XCTAssertEqual(verdict(elapsed: SpeechHealth.phantomWindow - 0.001),
                       .retry, "the boundary itself must stay retriable")
    }

    /// Bounded: one retry per read. A synthesizer that swallows twice is
    /// wedged, not racing, and the read ends honestly rather than looping.
    func testTheRetryHappensAtMostOnce() {
        XCTAssertEqual(verdict(retried: true), .giveUp)
    }

    /// Nothing left to say it with (the utterance was pruned, no read text)
    /// still ends the read HONESTLY — the capture is released rather than
    /// left live over silence, which would strand the keyboard.
    func testNothingToRespeakStillEndsTheReadRatherThanStranding() {
        XCTAssertEqual(verdict(canRespeak: false), .giveUp)
    }

    // MARK: - Recovery: a cancel, which is how macOS 27 reports a stop

    private func cancel(current: Bool = true, heard: Bool = false,
                        stopped: Bool = false, elapsed: TimeInterval = 0.05,
                        retried: Bool = false,
                        canRespeak: Bool = true) -> SpeechHealth.FinishVerdict {
        SpeechHealth.cancelVerdict(isCurrentUtterance: current,
                                   heardAudio: heard,
                                   stopRequested: stopped,
                                   elapsed: elapsed,
                                   alreadyRetried: retried,
                                   canRespeak: canRespeak)
    }

    /// The macOS 27 field shape, dozens of times in one log: `speak #N`,
    /// `didStart` at 0.01s, `didCancel` at 0.06s, no stop line, silence.
    /// Every one of those WAS a stop of ours (the read button's, see the
    /// silent-window tests) and so must stay `.stopped` — the retry must
    /// never fight a stop, however it was caused. This pins that a
    /// cancel with the stop flag set is a stop, evidence or no evidence.
    func testACancelAfterOurOwnStopIsAStop() {
        XCTAssertEqual(cancel(stopped: true), .stopped)
        XCTAssertEqual(cancel(stopped: true, heard: true), .spoken,
                       "…and one the user heard is an ordinary end")
    }

    /// The insurance: a cancel nobody asked for, before any sound, in
    /// milliseconds, is the queue eating the utterance — the macOS 26
    /// phantom in its macOS 27 costume. Retried, once, like a finish.
    func testAnUnaskedCancelBeforeAnySoundIsRetried() {
        XCTAssertEqual(cancel(), .retry)
        XCTAssertEqual(cancel(retried: true), .giveUp)
        XCTAssertEqual(cancel(canRespeak: false), .giveUp)
        XCTAssertEqual(cancel(current: false), .stale)
    }

    /// A cancel after a second of speaking time was SOMEBODY's stop, even
    /// one the flag cannot name (the rebuild's stop on the instance the
    /// watchdog gave up on lands here). It ends, and it is never logged as
    /// "reported no start" — that would be a lie about an utterance that
    /// had every chance to speak.
    func testASlowCancelIsAStopNotAPhantom() {
        XCTAssertEqual(cancel(elapsed: SpeechHealth.phantomWindow), .stopped)
        XCTAssertEqual(cancel(elapsed: 3.0), .stopped)
        XCTAssertEqual(cancel(elapsed: SpeechHealth.phantomWindow - 0.001),
                       .retry)
    }

    // MARK: - Drift guard

    private func speechEngineSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MardukTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        return try String(
            contentsOf: root.appendingPathComponent("Sources/Audio/SpeechEngine.swift"),
            encoding: .utf8)
    }

    /// The guard only works if EVERY handover goes through it. A second
    /// `synthesizer.speak(` anywhere in the engine is a path that enqueues
    /// without asking whether the instance is safe — which is the bug,
    /// reintroduced. (The echo/hover channel is a different instance,
    /// `echoSynthesizer`, and is deliberately not matched here: it never
    /// stops the read synthesizer, so it never runs this race.)
    ///
    /// A live AVSpeechSynthesizer flush race cannot be reproduced on a
    /// hosted runner, so this reads the source — the codebase's
    /// established escape hatch for logic behind a system boundary.
    func testOnlyOnePathHandsAnUtteranceToTheReadSynthesizer() throws {
        let source = try speechEngineSource()
        let handovers = source.components(separatedBy: "synthesizer.speak(").count - 1
        XCTAssertEqual(handovers, 1,
                       "every utterance must go through startSpeaking, which "
                         + "is where the fresh-instance guard lives")
    }

    /// …and that one path must consult the guard before it enqueues.
    func testTheHandoverConsultsTheGuardBeforeEnqueuing() throws {
        let source = try speechEngineSource()
        guard let guardAt = source.range(of: "needsFreshSynthesizer("),
              let speakAt = source.range(of: "synthesizer.speak(") else {
            return XCTFail("the handover guard is gone from SpeechEngine")
        }
        XCTAssertTrue(guardAt.lowerBound < speakAt.lowerBound,
                      "the utterance is enqueued before the instance is "
                        + "checked — the flush can still eat it")
    }

    /// `stop()` is what schedules the flush, so it is what must arm the
    /// suspicion. Without this line the guard never fires for the common
    /// case and the fix is inert.
    func testStopArmsTheSuspicion() throws {
        let source = try speechEngineSource()
        // Matched on the label, not the whole signature — `stop(reason:)`
        // carries a default and the reason vocabulary will grow.
        guard let start = source.range(of: "\n    func stop(reason:"),
              let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex)
        else { return XCTFail("stop() is no longer where this test expects it") }
        let body = String(source[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("stopSpeaking(at: .immediate)"),
                      "stop() no longer stops — this test is looking at the "
                        + "wrong function")
        XCTAssertTrue(body.contains("handoff.stopIssued()"),
                      "stop() schedules the queue flush but no longer arms "
                        + "the handoff guard, so the next utterance is "
                        + "handed to an instance that can still swallow it")
    }

    /// The fourth cause was didStart being taken for audio. The boundary
    /// callback is the only place allowed to say the user can hear
    /// something: a `heardAudioForCurrent = true` anywhere else (didStart
    /// is the tempting one) reopens the hole on macOS 27.
    func testOnlyTheWordBoundarySetsHeardAudio() throws {
        let source = try speechEngineSource()
        let sets = source.components(separatedBy: "heardAudioForCurrent = true").count - 1
        XCTAssertEqual(sets, 1, "heardAudio must be set by the word boundary "
                         + "callback and nothing else")
        guard let didStart = source.range(of: "didStart utterance: AVSpeechUtterance) {"),
              let didFinish = source.range(of: "didFinish utterance: AVSpeechUtterance) {")
        else { return XCTFail("the delegate methods moved") }
        let body = String(source[didStart.upperBound..<didFinish.lowerBound])
        XCTAssertFalse(body.contains("heardAudioForCurrent = true"),
                       "didStart is not evidence of audio on macOS 27")
        // …and the read button's question is answered from it, not from
        // didStart's flag.
        guard let starting = source.range(of: "var isStartingSilently: Bool {"),
              let end = source.range(of: "\n    }\n", range: starting.upperBound..<source.endIndex)
        else { return XCTFail("isStartingSilently moved") }
        let question = String(source[starting.upperBound..<end.lowerBound])
        XCTAssertTrue(question.contains("heardAudio: heardAudioForCurrent"))
        XCTAssertFalse(question.contains("sawStartForCurrent"))
    }

    /// A cancel is judged, never just torn down — that is what lets a
    /// phantom delivered as `didCancel` come back on its own.
    func testACancelIsJudgedBeforeItIsTornDown() throws {
        let source = try speechEngineSource()
        guard let didCancel = source.range(of: "didCancel utterance: AVSpeechUtterance) {"),
              let verdictAt = source.range(of: "SpeechHealth.cancelVerdict(",
                                           range: didCancel.upperBound..<source.endIndex),
              let finishAt = source.range(of: "finish(utterance)",
                                          range: didCancel.upperBound..<source.endIndex)
        else { return XCTFail("didCancel no longer consults the cancel verdict") }
        XCTAssertTrue(verdictAt.lowerBound < finishAt.lowerBound)
    }

    // MARK: - The field sequence, start to finish

    /// The exact log from 2026-08-08, replayed: a read ends, the user
    /// presses read again while the instance is still winding down, the
    /// second read is swallowed, and it comes back on its own.
    func testTheFieldSequenceRecoversWithoutAnotherKeypress() {
        var handoff = SpeechHealth.Handoff()

        // Read A: speaks, ends.
        handoff.handedOver()
        handoff.speechStarted()
        handoff.utteranceEnded()

        // Read B, moments later. stop() finds the instance still speaking.
        handoff.stopIssued()
        XCTAssertTrue(handoff.needsFreshSynthesizer(isSpeaking: true,
                                                    isPaused: false),
                      "read B must not be enqueued behind a pending flush")
        handoff.freshInstance()
        handoff.handedOver()

        // Suppose it is swallowed anyway (the residual case the guard
        // cannot see): nothing spoken, finish in milliseconds.
        XCTAssertEqual(verdict(elapsed: 0.008), .retry)

        // The retry starts and speaks. The user hears their read, having
        // pressed the button exactly once.
        handoff.freshInstance()
        handoff.handedOver()
        handoff.speechStarted()
        XCTAssertEqual(verdict(spoke: true, elapsed: 2.4, retried: true),
                       .spoken)
        handoff.utteranceEnded()
        XCTAssertFalse(handoff.needsFreshSynthesizer(isSpeaking: false,
                                                     isPaused: false))
    }
}
