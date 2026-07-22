import Foundation

/// Progressive, respectful onboarding: short contextual hints and one-key
/// config questions that surface the first time a feature naturally comes
/// up — spread out so a new user is never bombarded, always yielding to an
/// active read, silenceable (`:config hints off`), and quieting once the
/// user is clearly experienced. Main-thread-only, like `Tutorial`.
///
/// Two tiers:
/// - **Feature hints & config questions** (`offer`/`offerQuestion`): fully
///   paced — once-ever, a per-session cap, a cooldown between interjections,
///   and suppressed entirely once experienced. Only the caller's highest-
///   value eligible item should be offered per opportunity; the rest wait
///   for the next natural moment (next read end, next session).
/// - **Critical notices** (`notice`): permission/Karabiner/untested-macOS/
///   safe-mode — important enough to bypass the pacing gates, but still
///   once-ever and still yielding until speech is quiet.
final class Onboarding {
    /// Where a hint is allowed to speak. A tip has to arrive attached to
    /// the thing it describes (user ruling 2026-07-22): reading tips ride
    /// the gap between reading mode engaging and the content starting,
    /// others hang off the action they're about. `.standalone` is for the
    /// rare hint with no natural context — those may speak alone.
    enum Context {
        case readStart, pagedReadStart, rateChange, standalone
    }

    struct Hint {
        let id: String
        /// Every moment this hint may ride. A hint that fits both a plain
        /// and a paged read lists both rather than being duplicated —
        /// duplicate rows would let the same tip play twice under two ids.
        let contexts: Set<Context>
        let text: String
    }

    /// The hint ladder, ordered MOST CRITICAL FIRST and trailing off into
    /// advanced/niche (user ruling 2026-07-22: "low and slow"). Order is
    /// the priority: at any eligible moment the earliest unseen hint whose
    /// context matches wins, so a new user learns to control a read long
    /// before they hear about spelling or rate nudging. New hints are a
    /// TABLE ROW placed by importance — never a new code path.
    static let catalog: [Hint] = [
        // 1. Controlling a read at all — useless to hear anything else first
        Hint(id: "hint-read-motions", contexts: [.readStart, .pagedReadStart],
             text: "While I read: j and k move by line, Space pauses, and "
                 + "holding Escape stops."),
        // 2. Only matters once they meet a paged document
        Hint(id: "hint-page-keys", contexts: [.pagedReadStart],
             text: "This one reads in pages. Control F and Control B turn "
                 + "them, and Control G says where you are."),
        // 3. Advanced reading motion
        Hint(id: "hint-spell", contexts: [.readStart, .pagedReadStart],
             text: "While I read, z spells the current word."),
        // 4. Niche comfort setting
        Hint(id: "hint-speed-keys", contexts: [.rateChange],
             text: "You can also nudge the rate while I read: colon config "
                 + "speedkeys on, then Option with up or down."),
    ]

    // Wiring injected by the daemon
    var speak: ((String) -> Void)?      // → speech.announce
    var isSpeaking: (() -> Bool)?       // → speech.isSpeaking
    var persistProgress: ((Int, Date) -> Void)?

    var hintsEnabled: Bool
    private var hintsShown: Int
    private var tutored: Bool

    // Per-session pacing — the anti-bombard state
    private var sessionCount = 0
    private var lastHintAt: Date

    /// At most this many hints surface per daemon session…
    static let sessionCap = 1
    /// …and never within this window of the previous one. DAYS, not
    /// minutes (user ruling 2026-07-22: "space things out a LOT, like over
    /// several DAYS") — which is why `lastHintAt` is persisted to config
    /// rather than living for the lifetime of one daemon.
    static let cooldown: TimeInterval = 2 * 24 * 60 * 60
    /// After this many lifetime hints, onboarding goes quiet (feature
    /// discovery is done; critical notices still fire).
    static let experiencedThreshold = 12

    init(hintsEnabled: Bool, hintsShown: Int, tutored: Bool,
         lastHintAt: Date = .distantPast) {
        self.hintsEnabled = hintsEnabled
        self.hintsShown = hintsShown
        self.tutored = tutored
        self.lastHintAt = lastHintAt
    }

    var experienced: Bool { tutored || hintsShown >= Self.experiencedThreshold }

    /// Mark the guided tour complete — the strongest "this user gets it"
    /// signal, so feature hints stand down.
    func markTutored() {
        tutored = true
        OnceMarker.mark("tutored")
    }

    /// Pure pacing gate for feature hints & questions — CI-tested without
    /// touching the filesystem or the synthesizer. When in doubt, DON'T
    /// surface (a hint that interrupts a read is worse than one never shown).
    static func shouldSurface(seen: Bool, enabled: Bool, experienced: Bool,
                              sessionCount: Int, sinceLast: TimeInterval,
                              speaking: Bool) -> Bool {
        guard !seen, enabled, !experienced, !speaking else { return false }
        guard sessionCount < sessionCap else { return false }
        return sinceLast >= cooldown
    }

    private func eligible(_ id: String) -> Bool {
        Self.shouldSurface(seen: OnceMarker.seen(id), enabled: hintsEnabled,
                           experienced: experienced, sessionCount: sessionCount,
                           sinceLast: Date().timeIntervalSince(lastHintAt),
                           speaking: isSpeaking?() ?? false)
    }

    private func consume(_ id: String) {
        OnceMarker.mark(id)
        hintsShown += 1
        sessionCount += 1
        lastHintAt = Date()
        persistProgress?(hintsShown, lastHintAt)
        fputs("[onboarding] surfaced \(id) (\(hintsShown) lifetime)\n", stderr)
    }

    /// A one-line feature hint at a quiet moment. No-op unless eligible.
    @discardableResult
    func offer(_ id: String, _ text: String) -> Bool {
        guard eligible(id) else { return false }
        consume(id)
        speak?(text)
        return true
    }

    /// Claim the highest-priority hint for this context WITHOUT speaking
    /// it: returns its text (burning the once-ever marker) or nil.
    ///
    /// The caller speaks it and chains the real action to its completion,
    /// so a reading tip lands after reading mode engages but BEFORE the
    /// content — a preamble, never an interruption, and never the
    /// out-of-nowhere interjection that trailing hints produced.
    func claim(_ context: Context) -> String? {
        for hint in Self.catalog where hint.contexts.contains(context) {
            guard eligible(hint.id) else { continue }
            consume(hint.id)
            return hint.text
        }
        return nil
    }

    /// A first-use config question: speak the prompt, then let the caller
    /// arm the one-key capture (only if we actually surfaced). No-op unless
    /// eligible. The `arm` closure runs AFTER the prompt is queued.
    @discardableResult
    func offerQuestion(_ id: String, prompt: String, arm: () -> Void) -> Bool {
        guard eligible(id) else { return false }
        consume(id)
        speak?(prompt)
        arm()
        return true
    }

    /// A critical notice — once-ever, bypasses pacing, but yields until the
    /// synthesizer is quiet so it never talks over a read. Retries a few
    /// times, then stays unspoken until the next daemon start. Generalizes
    /// the old announceKarabinerAbsenceOnce / announceUntestedMacOSOnce.
    func notice(_ id: String, delay: TimeInterval, retries: Int, _ text: String) {
        guard !OnceMarker.seen(id) else { return }
        func attempt(_ remaining: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
                if isSpeaking?() ?? false {
                    if remaining > 0 { attempt(remaining - 1) }
                    return  // stay unnoticed; try again next start
                }
                OnceMarker.mark(id)
                speak?(text)
                fputs("[onboarding] notice \(id)\n", stderr)
            }
        }
        attempt(retries)
    }
}
