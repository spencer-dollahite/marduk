import Foundation

/// The inverter's decision core, pulled out pure so every state can be
/// exercised without firing a real Invert Colors keystroke or reading a
/// real display. Same shape as `ReadNavigator` and `HoverDwell`: the
/// judgment is a function, the side effects stay in `DisplayInverter`.
///
/// This exists because the inverter blinded a user three times in one day
/// and NONE of it was reachable by a test — the whole state machine sat
/// behind an osascript call. Every incident below is now a case in
/// InversionPolicyTests:
///   1. A "revert" fired on a BELIEVED-but-false inversion, and since the
///      hotkey is a blind toggle it INVERTED a dark-mode screen.
///   2. Gating reverts on ownership stranded an already-inverted display
///      white forever, because nothing was allowed to hand it back.
///   3. Inverting was reachable while reverting was gated off, so an
///      inversion could be created that nothing could ever undo.
enum InversionPolicy {

    /// What `ensureInverted` should do. `effective` is the display state
    /// after reconciling belief with reality — the caller adopts it either
    /// way, which is what keeps a stale flag from surviving a decision.
    enum Decision: Equatable {
        /// Neither invert nor autoinvert is on — never touch the display.
        case inactive
        /// Inside the toggle lockout; the heartbeat will re-ask.
        case lockedOut
        /// Display is already where we want it. Nothing to fire.
        case noChange(effective: Bool)
        /// Fire the toggle. `effective` is the state we're moving FROM.
        case fire(effective: Bool)
    }

    /// Resolve one invert/revert request.
    ///
    /// Order is deliberate and load-bearing: opt-in, then lockout, then
    /// reconcile belief against reality, and only then compare. Comparing
    /// before reconciling is precisely how a stale flag fires a toggle in
    /// the wrong direction.
    static func resolve(wanted: Bool, believed: Bool, actual: Bool,
                        active: Bool, sinceLastToggle: TimeInterval,
                        lockout: TimeInterval) -> Decision {
        guard active else { return .inactive }
        guard sinceLastToggle >= lockout else { return .lockedOut }
        // Reality wins over belief, always.
        return wanted == actual ? .noChange(effective: actual)
                                : .fire(effective: actual)
    }

    /// Should teardown hand the display back?
    ///
    /// Exit is the ONE place ownership matters: quitting must never flip a
    /// display Marduk didn't invert. It must also never fire on a belief,
    /// so the real state has to agree. (The heartbeat deliberately does
    /// NOT consult ownership — see incident 2 above.)
    static func shouldRevertOnExit(believed: Bool, actual: Bool,
                                   owned: Bool) -> Bool {
        believed && actual && owned
    }

    /// Is the subsystem live? EITHER switch opts the user in — and because
    /// this one value gates inverting AND reverting, the two can never be
    /// enabled independently, which is what made incident 3 possible.
    static func isActive(invertEnabled: Bool, autoInvert: Bool) -> Bool {
        invertEnabled || autoInvert
    }
}
