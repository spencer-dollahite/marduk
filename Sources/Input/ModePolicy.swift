import Foundation

/// Mode transitions and the Escape gesture, pure.
///
/// The modal ladder is the product's spine, and every rung of it lived
/// inside a 1,100-line `handleEvent` taking a `CGEvent`, so none of it
/// could be tested. Field 2026-07-22: a held Escape in a windowed Terminal
/// read dropped to NORMAL and was instantly undone by paged window
/// continuation, over and over — the user could not leave a 1,309-page
/// read at all. That bug lived in the speech engine, but nothing here
/// could have caught it either, because none of these rules were pinned.
///
/// Same shape as `BurstPolicy`, `InversionPolicy`, `ReadNavigator`.
enum ModePolicy {

    typealias Mode = KeyboardMonitor.Mode

    /// Where a HELD Escape lands. The ladder is climbed one rung per hold
    /// and the rung is audible: reclaiming READING ends a whole tone lower
    /// than reaching NORMAL, so the user can hear which level they got.
    enum EscapeDestination: Equatable {
        /// INSERT entered from a live read: the hold RECLAIMS the read
        /// rather than leaving, because the read is still playing.
        case reclaimReading
        /// The ordinary exit — INSERT or READING or VISUAL → NORMAL.
        case normal
        /// Nothing to leave; the app should see the Escape.
        case passToApp
    }

    /// A held Escape climbs exactly one rung.
    ///
    /// The INSERT case is the subtle one: `i` during a read leaves the
    /// read PLAYING and suspends the capture, so a hold from there must
    /// return to READING (not all the way to NORMAL) — otherwise the user
    /// who typed a note mid-read is dumped two levels down and the read
    /// keeps going with no capture to control it.
    static func escapeHoldDestination(mode: Mode, readActive: Bool,
                                      readMotionsEnabled: Bool,
                                      enabled: Bool) -> EscapeDestination {
        guard enabled else { return .passToApp }
        switch mode {
        case .insert:
            // Only reclaim when there is genuinely a read to reclaim AND
            // read motions are on — otherwise READING is not a place the
            // user can be, and the hold must reach NORMAL.
            return (readActive && readMotionsEnabled) ? .reclaimReading : .normal
        case .visual, .visualLine:
            return .normal
        case .normal:
            return .passToApp
        case .command:
            // COMMAND owns Escape outright (it cancels the command line)
            return .passToApp
        }
    }

    /// A TAPPED Escape. Tap and hold are the same key, so the distinction
    /// is time — and every mode answers a tap differently.
    enum EscapeTap: Equatable {
        /// Deliver the Escape to the app on key release (vim and Claude
        /// Code must keep their Escape).
        case deliverToApp
        /// Toggle pause/resume of the active read — exactly like Space.
        case togglePause
        /// Cancel a paused read that is holding Space hostage.
        case stopPausedRead
        /// Leave VISUAL.
        case exitVisual
        /// Cancel the command line.
        case cancelCommand
    }

    static func escapeTap(mode: Mode, readingCapture: Bool,
                          readActive: Bool, readPaused: Bool) -> EscapeTap {
        if readingCapture { return .togglePause }
        switch mode {
        case .insert: return .deliverToApp
        case .visual, .visualLine: return .exitVisual
        case .command: return .cancelCommand
        case .normal:
            // A paused read still reports as speaking and holds Space
            // captive; Escape in NORMAL is what frees it.
            return readPaused ? .stopPausedRead : .deliverToApp
        }
    }

    /// May a read CAPTURE the keyboard right now?
    ///
    /// Entry is skipped in COMMAND on purpose: a confirmation read fired
    /// by a `:config` command must never steal the palette's keys
    /// mid-command (field regression).
    static func shouldCaptureForRead(readActive: Bool, mode: Mode,
                                     readMotionsEnabled: Bool, enabled: Bool,
                                     alreadyCapturing: Bool) -> Bool {
        guard readActive, readMotionsEnabled, enabled else { return false }
        guard !alreadyCapturing else { return false }
        return mode != .command
    }

    /// Should a paged read flow into its next window?
    ///
    /// This is the rule the field bug broke. The engine used to infer it
    /// from didFinish-vs-didCancel, but a synthesizer stopped while paused
    /// reports didFinish — so a user stop read as "the window ended
    /// naturally" and the read restarted itself forever.
    static func shouldContinueWindow(stopRequested: Bool, isCurrentUtterance: Bool,
                                     hasNextWindow: Bool) -> Bool {
        !stopRequested && isCurrentUtterance && hasNextWindow
    }

    /// Where `gg` / `G` land.
    ///
    /// On a paged read the document edges are PAGES. On a plain read they
    /// are text offsets. The two edges must be treated SYMMETRICALLY: `G`
    /// was paged-aware and `gg` was not, so gg fell through to a text
    /// offset of 0 — which on a windowed read is the start of the CURRENT
    /// WINDOW, not the document. In a 1,336-page Terminal read opened at
    /// page 664 that looked like a jump to a random spot.
    enum DocumentEdge: Equatable {
        case page(Int)      // 1-based
        case textOffset     // let the navigator resolve it in the window
    }

    static func documentEdge(forward: Bool, isPaged: Bool,
                             pageCount: Int) -> DocumentEdge {
        guard isPaged else { return .textOffset }
        return .page(forward ? pageCount : 1)
    }
}
