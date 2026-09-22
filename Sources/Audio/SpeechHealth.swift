import Foundation

/// The rules that keep a read from being lost in silence.
///
/// Speech is the only output this product has. A read that never speaks is
/// not a cosmetic glitch — it is the whole interface failing, and to a user
/// who cannot see the screen it is indistinguishable from a missed
/// keypress. Two field campaigns (2026-08-06, 2026-08-08) traced the
/// intermittent "it starts and then quickly stops without reading
/// anything" to ONE mechanism with two halves, both modelled here so they
/// can be tested without a synthesizer.
///
/// **The hazard.** `AVSpeechSynthesizer` is a QUEUE, and
/// `stopSpeaking(at:)` does not empty it synchronously — it schedules the
/// flush. `speak()`, `announce()`, `speakSSML()` and `respeak()` all call
/// `stop()` and then hand over a new utterance in the SAME turn, so when
/// the flush lands after that enqueue it removes the brand-new utterance
/// along with the old one. The newcomer comes straight back to the
/// delegate as an END, with no start, having spoken nothing. (On macOS 26
/// it arrives as `didFinish`, not `didCancel`: in a full field log
/// covering hundreds of stops there is not one `didCancel` line — a
/// cancelled utterance reports as finished, which is also why paged
/// continuation keys off `stopRequested` rather than the callback. macOS
/// 27 changed BOTH signals — see "the fourth cause" below.)
///
/// That timing is why the bug looked random and why the very same
/// selection read fine on the next press: by then the synthesizer is idle,
/// `stop()` never issues a flush at all, and there is nothing to eat the
/// utterance.
///
/// **The two halves.** `Handoff` prevents the loss — never enqueue into an
/// instance with an unresolved stop. `finishVerdict` recovers from one
/// that happened anyway, because the guard can only act on the signals the
/// synthesizer gives us and it gives us very few.
///
/// **The fourth cause — macOS 27 (field 2026-09-22).** The same complaint
/// came back the week after the upgrade ("sometimes it starts reading
/// perfectly and other times it goes quiet and never reads the text, and
/// music resumes"), with a new shape in the log: `didStart` after 0.01s,
/// `didCancel` 0.02–0.6s later, no stop line, then the user's second press
/// two seconds on, which reads fine `[fresh synthesizer: stop flush
/// unconfirmed]`. Two things had changed underneath us. (1) `didStart` now
/// fires the instant the queue ACCEPTS the utterance — 1148 of 1316
/// utterances started in under 50ms, against 0.2–1.0s on macOS 26 — so it
/// is no longer evidence of audio, and the third cause's guard (which took
/// didStart as proof) stood down the moment it fired: 62 duplicate presses
/// absorbed on macOS 26, 4 on 27, and the rest went to the "audibly
/// speaking → stop" branch and killed the read this button had just asked
/// for. (2) A stop now reports `didCancel`, routinely (236 lines in one
/// log), and that path went straight to teardown — no verdict, no log of
/// why. The missing stop line was the same lie: `stop(reason:)` reported
/// "landed before it made a sound" only when didStart had not come, and on
/// 27 it always had. The "stop flush unconfirmed" on the retry press is
/// the proof a `stop()` of ours fired: nothing else arms that flag.
///
/// The fix is to stop trusting didStart for anything the user can feel:
/// the read button's guard now wants a WORD BOUNDARY (the synthesizer
/// saying "I am about to voice this word" — proof of audio on every macOS
/// so far) and, belt and braces, treats any press inside `bounceFloor` of
/// the handover as the bounce it is; the stop line reports against the
/// same evidence; and a cancel is judged like a finish, so a phantom that
/// arrives as `didCancel` is retried instead of mistaken for Escape.
enum SpeechHealth {

    // MARK: - Prevention: which instance is safe to speak into

    /// Everything we can honestly know about one synthesizer instance's
    /// readiness to accept work. Deliberately made of OBSERVED EVENTS
    /// rather than elapsed time: a delay long enough to be safe would also
    /// be long enough to hear, and the whole failure is that we cannot ask
    /// the synthesizer what it is doing.
    struct Handoff: Equatable {
        /// We issued `stopSpeaking` and have not seen this instance speak
        /// since. The flush may still be pending, and a pending flush eats
        /// whatever is in the queue — including an utterance enqueued
        /// after the stop was requested.
        private(set) var stopFlushPending = false
        /// An utterance was handed over and its end callback has not
        /// arrived. Anything we enqueue now is an INTERRUPTION, which is
        /// exactly the case that runs the race.
        private(set) var utteranceOutstanding = false

        init() {}

        /// `stop()` touched the synthesizer.
        mutating func stopIssued() { stopFlushPending = true }

        /// An utterance was enqueued on this instance.
        mutating func handedOver() { utteranceOutstanding = true }

        /// The instance proved it is healthy the only way that counts: it
        /// started speaking. A flush that was going to eat this utterance
        /// did not, so the suspicion is over.
        ///
        /// Note this is NOT cleared by the end callback of the stopped
        /// utterance, tempting as that is. The callback and the flush are
        /// two different events with no guaranteed order — clearing on the
        /// callback would declare the instance clean in exactly the
        /// interleaving the guard exists to catch.
        mutating func speechStarted() { stopFlushPending = false }

        /// The outstanding utterance's end callback arrived.
        mutating func utteranceEnded() { utteranceOutstanding = false }

        /// A brand-new instance: nothing queued, nothing in flight.
        mutating func freshInstance() {
            stopFlushPending = false
            utteranceOutstanding = false
        }

        /// True when handing this instance an utterance risks it being
        /// swallowed. `isSpeaking`/`isPaused` are the synthesizer's own
        /// (lagging, occasionally lying) signals — they catch the case
        /// where a natural finish has been reported but the teardown is
        /// still winding down, which is where the field failures cluster.
        ///
        /// The answer is a FRESH INSTANCE rather than a wait. A new
        /// synthesizer has no queue and no flush in flight, so the enqueue
        /// cannot be eaten; waiting would mean guessing a duration for an
        /// event we cannot observe.
        func needsFreshSynthesizer(isSpeaking: Bool, isPaused: Bool) -> Bool {
            stopFlushPending || utteranceOutstanding || isSpeaking || isPaused
        }
    }

    // MARK: - The silent window between "handed over" and "audible"

    /// How long an utterance may sit between the enqueue and its first
    /// sound before we stop calling it "starting". Observed first-start
    /// latencies in the field run 0.2s on a warm synthesizer and up to
    /// ~1.0s on a cold one (a rebuilt instance, a voice being paged in),
    /// so the window has to clear a full second. Past it, something is
    /// wrong rather than slow — the 4s watchdog owns that case, and a
    /// keypress must not be swallowed indefinitely by a wedge.
    static let startupGrace: TimeInterval = 1.5

    /// A read-button press this soon after the button's own read was
    /// handed over is not a decision, it is the switch bouncing (or a
    /// repeat the HID layer never flagged): nobody asks for a read and
    /// silences it a quarter-second later. The duplicate presses in every
    /// field log land 0.02–0.2s after the first, on both macOS 26 and 27.
    /// Inside this floor the press is ignored even when the synthesizer
    /// swears it is audible — which on macOS 27 it does at 0.01s, before
    /// any sound (the fourth cause). Escape is not covered: Escape means
    /// stop.
    static let bounceFloor: TimeInterval = 0.25

    /// True while a read has been handed to the synthesizer and has made
    /// NO SOUND YET.
    ///
    /// This state is the reason the swallowed read kept coming back after
    /// the handoff guard and the phantom retry both landed. Neither could
    /// see it, because nothing was racing: `AVSpeechSynthesizer.isSpeaking`
    /// goes true the instant the QUEUE accepts an utterance, a quarter to
    /// a full second before the first syllable — and to every consumer of
    /// that flag, a read that has said nothing is indistinguishable from
    /// one the user is listening to. So the read button's three-way read
    /// "audibly speaking" and took its "stop only" branch, silencing the
    /// read that the very same button had asked for a moment earlier. The
    /// stop set `stopRequested`, the finish that followed was therefore
    /// judged `.stopped` — a user asking for silence, never retried, by
    /// design — and the read died without one syllable or one line of
    /// evidence that anything had gone wrong (field 2026-08-09: five reads
    /// in one session, each ending 0.10-0.56s after a press, each followed
    /// by "fresh synthesizer: stop flush unconfirmed").
    ///
    /// - Parameter heardAudio: a WORD-BOUNDARY callback arrived for this
    ///   utterance. Not didStart: on macOS 27 didStart fires when the queue
    ///   accepts the utterance, 10ms after handover and well before any
    ///   sound, so taking it as evidence reopened this exact hole (the
    ///   fourth cause, 2026-09-22). The boundary is the synthesizer
    ///   announcing the word it is about to voice — the one callback that
    ///   has meant audio on every macOS so far. If boundaries ever lapse
    ///   the cost is bounded: the button is a no-op for `startupGrace` of
    ///   an audible read, and Escape still stops it.
    ///
    /// `isPaused` is excluded deliberately: a paused read HAS spoken, and
    /// its press means something else entirely (stop the old read, read
    /// the new selection).
    static func isSilentStartup(isSpeaking: Bool, isPaused: Bool,
                                heardAudio: Bool,
                                sinceHandover: TimeInterval?) -> Bool {
        guard isSpeaking, !isPaused, let since = sinceHandover else { return false }
        if since < bounceFloor { return true }
        return !heardAudio && since < startupGrace
    }

    // MARK: - Recovery: reading a finish that spoke nothing

    /// Too fast for anything to have been said. Phantoms come back in
    /// milliseconds; the shortest real read in the field log (12 chars)
    /// takes about 0.6s. Re-speaking something the user ALREADY HEARD is a
    /// worse bug than the one being fixed, so the recovery is bounded on
    /// the safe side by this as well as by the evidence test.
    static let phantomWindow: TimeInterval = 1.0

    enum FinishVerdict: Equatable {
        /// An utterance we already replaced. Its callbacks say nothing
        /// about the health of the read now in flight.
        case stale
        /// A real end of real speech.
        case spoken
        /// The user asked for silence before it started. Same SHAPE as a
        /// phantom (no start, immediate end) and must never be retried —
        /// re-speaking here would fight the Escape that stopped it.
        case stopped
        /// Nothing was spoken and it is safe to say it again.
        case retry
        /// Nothing was spoken and we will not try again — already retried,
        /// or too slow to be sure the user heard nothing. Ends the read
        /// honestly rather than stranding a live capture over silence.
        case giveUp
    }

    /// - Parameters:
    ///   - sawEvidenceOfSpeech: didStart OR a word-boundary callback for
    ///     this utterance. Either one proves audio, and requiring BOTH to
    ///     lapse is what keeps a read the user heard from being repeated —
    ///     delegate delivery has been seen to lapse while plainly audible.
    ///   - canRespeak: the engine still holds enough to say it again.
    static func finishVerdict(isCurrentUtterance: Bool,
                              sawEvidenceOfSpeech: Bool,
                              stopRequested: Bool,
                              elapsed: TimeInterval,
                              alreadyRetried: Bool,
                              canRespeak: Bool) -> FinishVerdict {
        guard isCurrentUtterance else { return .stale }
        guard !sawEvidenceOfSpeech else { return .spoken }
        guard !stopRequested else { return .stopped }
        guard elapsed < phantomWindow else { return .giveUp }
        guard !alreadyRetried, canRespeak else { return .giveUp }
        return .retry
    }

    /// The same judgment for a `didCancel`, which on macOS 27 is how a
    /// stop — ours or the queue's — comes back. It used to go straight to
    /// teardown, so a phantom delivered as a cancel could never be
    /// retried, and the log could not say whether a cancel was Escape or
    /// the synthesizer eating a read.
    ///
    /// Stricter than the finish verdict in two places, because a cancel
    /// is a stop until proven otherwise:
    /// - `heardAudio` is the word boundary ONLY. didStart is not evidence
    ///   here (the fourth cause) — but neither is its absence proof of
    ///   silence on macOS 26, so a finish keeps its didStart-or-boundary
    ///   test where the retry risk runs the other way.
    /// - A cancel past `phantomWindow` is `.stopped`, never `.giveUp`: it
    ///   arrived after a second of speaking time, so somebody stopped it,
    ///   even if we cannot name who (a rebuild's stop on the instance the
    ///   4s watchdog gave up on lands here). Ending it is right; logging
    ///   "reported no start" about it would be a lie.
    static func cancelVerdict(isCurrentUtterance: Bool,
                              heardAudio: Bool,
                              stopRequested: Bool,
                              elapsed: TimeInterval,
                              alreadyRetried: Bool,
                              canRespeak: Bool) -> FinishVerdict {
        guard isCurrentUtterance else { return .stale }
        guard !heardAudio else { return .spoken }
        guard !stopRequested, elapsed < phantomWindow else { return .stopped }
        guard !alreadyRetried, canRespeak else { return .giveUp }
        return .retry
    }

    /// Why a fresh instance was swapped in, for the log. Ids and reasons
    /// only — the log carries no user content, ever.
    static func freshReason(_ handoff: Handoff, isSpeaking: Bool,
                            isPaused: Bool) -> String {
        var reasons: [String] = []
        if handoff.stopFlushPending { reasons.append("stop flush unconfirmed") }
        if handoff.utteranceOutstanding { reasons.append("previous utterance unresolved") }
        if isSpeaking { reasons.append("still speaking") }
        if isPaused { reasons.append("paused") }
        return reasons.isEmpty ? "unknown" : reasons.joined(separator: ", ")
    }
}
