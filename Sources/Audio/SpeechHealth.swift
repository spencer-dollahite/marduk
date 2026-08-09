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
/// delegate as an END, with no start, having spoken nothing. (It arrives
/// as `didFinish`, not `didCancel`: in a full field log covering hundreds
/// of stops there is not one `didCancel` line — on macOS 26 a cancelled
/// utterance reports as finished, which is also why paged continuation
/// keys off `stopRequested` rather than the callback.)
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
    /// `isPaused` is excluded deliberately: a paused read HAS spoken, and
    /// its press means something else entirely (stop the old read, read
    /// the new selection).
    static func isSilentStartup(isSpeaking: Bool, isPaused: Bool,
                                sawEvidenceOfSpeech: Bool,
                                sinceHandover: TimeInterval?) -> Bool {
        guard isSpeaking, !isPaused, !sawEvidenceOfSpeech,
              let since = sinceHandover else { return false }
        return since < startupGrace
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
