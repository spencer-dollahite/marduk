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
        /// Neither invertapps nor smartinvert is on — never touch the display.
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

    // MARK: - Manual-revert respect

    /// Did the USER revert the display out from under us?
    ///
    /// We believed the display was inverted, we OWN that inversion, and
    /// reality says it is not — the only hand that produces that state is
    /// the user's own Invert Colors key (field 2026-07-28: a dialog over
    /// an inverted Pages made the user revert manually, and the heartbeat
    /// re-fired the toggle over them every beat — a fight).
    ///
    /// `settle` keeps a FAILED toggle of our own from masquerading as a
    /// manual revert: right after we fire, belief says inverted while the
    /// keystroke may not have landed yet. `verifyInversion` resyncs that
    /// case at 2s (belief and ownership both drop), so any detection past
    /// 3s is genuinely the user's doing.
    static func manualRevertDetected(believed: Bool, actual: Bool, owned: Bool,
                                     sinceLastToggle: TimeInterval,
                                     settle: TimeInterval) -> Bool {
        believed && owned && !actual && sinceLastToggle >= settle
    }

    /// While a manual revert is being respected, what does the override
    /// mean for the app now in front?
    enum OverrideState: Equatable {
        /// Not the overridden app — invert as normal.
        case none
        /// The overridden app, and it hasn't been away long enough — the
        /// user's choice still stands.
        case suppressed
        /// The overridden app returns after a real absence — a fresh
        /// visit, invert again.
        case expired
    }

    /// `sinceSeen` is time since the overridden app was last seen front
    /// (refreshed every heartbeat while it stays there), so the absence
    /// clock only runs while the user is genuinely elsewhere — a hop to a
    /// dialog and back never re-inverts.
    static func overrideState(front: String, holder: String?,
                              sinceSeen: TimeInterval,
                              away: TimeInterval) -> OverrideState {
        guard front == holder else { return .none }
        return sinceSeen > away ? .expired : .suppressed
    }
}
