import Foundation

/// The typing-rescue burst decision, pulled out pure.
///
/// This is the highest-consequence judgment in the product: in NORMAL
/// mode, unmodified letters are WITHHELD for ~300ms and then either
/// executed as commands or replayed into the app as typing. Get it wrong
/// in one direction and the user's keystrokes vanish; get it wrong in the
/// other and typing "sun" fires three commands. It lived inside a
/// 130-line method taking a `CGEvent` and returning
/// `Unmanaged<CGEvent>?`, so none of it was reachable by a test.
///
/// The judgment reads NOTHING but keycodes and four booleans, so it
/// extracts cleanly. `burstIntercept` keeps every side effect — copying
/// events, redispatching, replaying, firing callbacks — and this decides
/// only WHAT should happen.
///
/// Same shape as `ReadNavigator`, `HoverDwell`, and `InversionPolicy`.
enum BurstPolicy {

    /// The three double-tap gestures resolved inside the burst window.
    enum DoubleTap: Equatable {
        case time     // tt → speak time + date
        case update   // uu → express update
        case release  // dd → cut a patch release (source installs only)
    }

    enum Verdict: Equatable {
        /// The burst layer has no opinion — fall through to the regular
        /// command dispatch (the method's `nil`).
        case passThrough
        /// Autorepeat of a letter while a decision is pending: absorbed so
        /// a held key can't machine-gun beeps or commands.
        case swallowRepeat
        /// First letter of a possible burst: withhold it and arm the timer.
        case startBuffer
        /// Still all-command letters — keep collecting.
        case append
        /// A non-command letter appeared: this is typing. Switch to INSERT
        /// and replay everything withheld.
        case declareTyping
        /// A double-tap resolved. The buffered PREFIX still flushes (the
        /// `s` in `s-t-t` is a real command and must not be eaten); the
        /// first key of the pair itself is consumed by the gesture.
        case doubleTap(DoubleTap)
        /// `v` followed by a motion — deliberate fast visual-mode use.
        /// Flush the `v` synchronously, then redispatch the motion.
        case flushThenRedispatch
        /// A non-letter arrived with a burst pending: resolve the burst as
        /// commands, then let this key take its normal (possibly
        /// mode-changed) route.
        case flushThenRoute
    }

    /// NORMAL-mode letters that are commands: s v r t u i. `i` counts —
    /// mid-buffer it is a plausible deliberate command, and any following
    /// non-command letter still flips the decision to typing.
    static let commandLetterKeys: Set<Int64> = [1, 9, 15, 17, 32, 34]

    /// Visual motions that may legitimately follow a withheld `v`/`V`:
    /// h j k l and g/G. No English word starts with those pairs, so fast
    /// `vj`/`vG` power-use keeps working with zero added latency.
    static let visualMotionKeys: Set<Int64> = [4, 38, 40, 37, 5]

    static let kKey: Int64 = 40
    static let iKey: Int64 = 34
    static let tKey: Int64 = 17
    static let uKey: Int64 = 32
    static let dKey: Int64 = 2
    static let vKey: Int64 = 9

    /// `n` (45) is a command ONLY while Firefox is frontmost (Reader
    /// narration handoff). Everywhere else it stays a plain letter, which
    /// is what keeps all-command-plus-n words ("sun", "runs") rescuing as
    /// typing.
    static func isCommandLetter(_ keycode: Int64, firefoxFrontmost: Bool) -> Bool {
        commandLetterKeys.contains(keycode)
            || (keycode == 45 && firefoxFrontmost)
    }

    /// Decide what a NORMAL-mode keypress means while typing rescue is on.
    ///
    /// `buffer` is the keycodes currently withheld, oldest first.
    /// `isLetter` is the caller's letter test (alpha keys plus `k`), passed
    /// in because that definition is used elsewhere in the tap too.
    static func classify(buffer: [Int64], keycode: Int64, isLetter: Bool,
                         isAutorepeat: Bool, firefoxFrontmost: Bool,
                         releaseAvailable: Bool) -> Verdict {
        guard isLetter else {
            // Space, digit, arrow, Escape… resolve any pending burst first
            return buffer.isEmpty ? .passThrough : .flushThenRoute
        }

        if isAutorepeat {
            // Held `k` keeps repeating into the app even while a burst is
            // pending — its repeats are app-bound input (scroll), not
            // no-ops, and must not stall for the decision window.
            return keycode == kKey ? .passThrough : .swallowRepeat
        }

        if buffer.isEmpty {
            // `i` → instant INSERT (the i-then-type flow must have zero
            // latency); `k` keeps its pass-through. Neither starts a buffer.
            return (keycode == iKey || keycode == kKey) ? .passThrough : .startBuffer
        }

        // Double taps resolve immediately — strictly faster than waiting
        // for the timer, and they can only match against a buffered twin.
        if keycode == tKey, buffer.last == tKey { return .doubleTap(.time) }
        if keycode == uKey, buffer.last == uKey { return .doubleTap(.update) }
        // On release/Homebrew machines the gesture DOES NOT EXIST, so
        // double-d words keep their typing rescue and a stranger's install
        // has zero surface for it.
        if releaseAvailable, keycode == dKey, buffer.last == dKey {
            return .doubleTap(.release)
        }

        if visualMotionKeys.contains(keycode), buffer.first == vKey {
            return .flushThenRedispatch
        }

        // A burst containing any non-command letter means typing. A
        // non-command letter can only ever sit at buffer position 0 (a
        // later one resolves the burst right here), so checking the head
        // plus the incoming key covers the whole buffer — this is what
        // rescues "hi"/"he"/"at", where the command letter comes second.
        let headIsCommand = isCommandLetter(buffer[0],
                                            firefoxFrontmost: firefoxFrontmost)
        if headIsCommand, isCommandLetter(keycode, firefoxFrontmost: firefoxFrontmost) {
            // Still ambiguous (all commands so far) — keep collecting. On
            // expiry the whole buffer executes as commands, so deliberate
            // rapid command pairs (s then r) stay commands.
            return .append
        }
        return .declareTyping
    }
}
