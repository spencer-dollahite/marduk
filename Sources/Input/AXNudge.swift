import Foundation
import ApplicationServices

/// The accessibility flags Marduk sets on OTHER processes, and the promise
/// to take them back.
///
/// WHY THIS EXISTS: two harvest paths announce Marduk to an app the way
/// VoiceOver does — `AXEnhancedUserInterface` (the AppKit/WebKit/Gecko
/// signal) and `AXManualAccessibility` (the Chromium/Electron one) — because
/// browsers keep their web AX trees minimal and iWork keeps table cells
/// empty until an assistive client says it is there. Both flags were set
/// and NEVER cleared. They are per-PROCESS and they outlive the read: an
/// app carries them until it quits, and the user's browser and chat apps
/// run for days. With the flag on, an AppKit app keeps its full AX
/// machinery hot and Chromium/Electron switch into full accessibility mode
/// — the documented "Chrome is slow with accessibility on" state, where every
/// DOM mutation is mirrored into an accessibility tree that grows with tab
/// use. That is exactly the shape of "after several days everything is
/// sluggish", and it lives in a process the health line cannot see from
/// inside Marduk. VoiceOver sets these flags while it runs and clears them
/// when it stops; Marduk now does the same, scoped to the READ: set for the
/// walk, held while the read's scroll-follow anchors are alive, restored
/// when the read ends — or when Marduk disengages, quits, or the read
/// never starts.
///
/// One door: this is the ONLY file allowed to name either attribute
/// (`ResourceHygieneTests` enforces it), so a future harvest rung cannot
/// quietly set a flag the ledger does not know to restore.
struct AXNudgeLedger: Equatable {
    struct Flags: OptionSet, Equatable {
        let rawValue: Int
        static let enhanced = Flags(rawValue: 1)   // AXEnhancedUserInterface
        static let manual = Flags(rawValue: 2)     // AXManualAccessibility
    }

    private(set) var held: [pid_t: Flags] = [:]

    /// Record flags set on `pid`. Repeats union rather than duplicate — a
    /// second read into the same app owes the same restore, not two.
    mutating func note(_ pid: pid_t, _ flags: Flags) {
        guard pid > 0, !flags.isEmpty else { return }
        held[pid, default: []].formUnion(flags)
    }

    /// Everything owed, and the ledger emptied. Order is deterministic so
    /// a log of "restored 2 apps" is reproducible.
    mutating func drain() -> [(pid: pid_t, flags: Flags)] {
        let owed = held.keys.sorted().map { (pid: $0, flags: held[$0]!) }
        held.removeAll()
        return owed
    }

    /// A process that quit owes nothing — its flags died with it, and a
    /// recycled PID must never receive a stranger's restore.
    mutating func forget(_ pid: pid_t) {
        held.removeValue(forKey: pid)
    }

    var count: Int { held.count }
}

/// The live side: sets the flags (recording them) and restores them off
/// the main thread. Thread-safe — harvest walks run on utility queues while
/// read-end and teardown arrive on main.
final class AXNudge {
    static let shared = AXNudge()

    private var ledger = AXNudgeLedger()
    private let lock = NSLock()

    /// Flags currently set on other processes by us. Between reads this
    /// should be ZERO; the health line reports it so a restore that stops
    /// firing shows up as a climbing number instead of a slow machine.
    var heldCount: Int {
        lock.lock(); defer { lock.unlock() }
        return ledger.count
    }

    /// Announce Marduk to `pid`. Returns the first non-success error so the
    /// caller can log it (an app that answers NotImplemented never took the
    /// flag; restoring it later is then a harmless no-op).
    @discardableResult
    func enhance(pid: pid_t, flags: AXNudgeLedger.Flags,
                 timeout: Float = 0.25) -> AXError {
        guard pid > 0 else { return .invalidUIElement }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var first: AXError = .success
        for (flag, name) in Self.attributeNames where flags.contains(flag) {
            let err = AXUIElementSetAttributeValue(app, name as CFString, kCFBooleanTrue)
            if err != .success, first == .success { first = err }
        }
        lock.lock()
        ledger.note(pid, flags)
        lock.unlock()
        return first
    }

    /// Take every flag back. Off-main: each set is an AX round trip into
    /// another process with a timeout, and this is called from read-end
    /// and teardown paths that own the main thread. Logs counts only.
    func restoreAll(reason: String) {
        lock.lock()
        let owed = ledger.drain()
        lock.unlock()
        guard !owed.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for entry in owed {
                let app = AXUIElementCreateApplication(entry.pid)
                AXUIElementSetMessagingTimeout(app, 0.25)
                for (flag, name) in Self.attributeNames where entry.flags.contains(flag) {
                    AXUIElementSetAttributeValue(app, name as CFString, kCFBooleanFalse)
                }
            }
            fputs("[keyboard] AX flags restored on \(owed.count) app(s) (\(reason))\n",
                  stderr)
        }
    }

    /// Synchronous variant for process exit, where a dispatched restore
    /// would never run. Bounded by the per-call timeout.
    func restoreAllNow(reason: String) {
        lock.lock()
        let owed = ledger.drain()
        lock.unlock()
        guard !owed.isEmpty else { return }
        for entry in owed {
            let app = AXUIElementCreateApplication(entry.pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            for (flag, name) in Self.attributeNames where entry.flags.contains(flag) {
                AXUIElementSetAttributeValue(app, name as CFString, kCFBooleanFalse)
            }
        }
        fputs("[keyboard] AX flags restored on \(owed.count) app(s) (\(reason))\n",
              stderr)
    }

    func forget(pid: pid_t) {
        lock.lock()
        ledger.forget(pid)
        lock.unlock()
    }

    private static let attributeNames: [(AXNudgeLedger.Flags, String)] = [
        (.enhanced, "AXEnhancedUserInterface"),
        (.manual, "AXManualAccessibility"),
    ]
}
