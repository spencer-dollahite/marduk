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
    // Wiring injected by the daemon
    var speak: ((String) -> Void)?      // → speech.announce
    var isSpeaking: (() -> Bool)?       // → speech.isSpeaking
    var persistHintsShown: ((Int) -> Void)?

    var hintsEnabled: Bool
    private var hintsShown: Int
    private var tutored: Bool

    // Per-session pacing — the anti-bombard state
    private var sessionCount = 0
    private var lastHintAt = Date.distantPast

    /// At most this many hints/questions surface per daemon session…
    static let sessionCap = 2
    /// …and never within this window of the previous one.
    static let cooldown: TimeInterval = 120
    /// After this many lifetime hints, onboarding goes quiet (feature
    /// discovery is done; critical notices still fire).
    static let experiencedThreshold = 12

    init(hintsEnabled: Bool, hintsShown: Int, tutored: Bool) {
        self.hintsEnabled = hintsEnabled
        self.hintsShown = hintsShown
        self.tutored = tutored
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
        persistHintsShown?(hintsShown)
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

    /// `:onboarding reset` — start the progressive experience over.
    func reset(clearing ids: [String]) {
        ids.forEach { OnceMarker.clear($0) }
        hintsShown = 0
        sessionCount = 0
        lastHintAt = Date.distantPast
        tutored = false
        persistHintsShown?(0)
        fputs("[onboarding] reset\n", stderr)
    }
}
