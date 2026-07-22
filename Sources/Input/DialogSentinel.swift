import Foundation
import AppKit
import ApplicationServices

/// Announces dialogs that need attention — the overlays a zoomed-in or
/// low-vision user cannot see appear: password prompts, permission (TCC)
/// dialogs, system alerts, and in-app sheets/alert dialogs.
///
/// Two detectors:
/// 1. SYSTEM AGENTS: password/permission/alert dialogs come from a small
///    set of dedicated processes that take focus when they appear — a
///    workspace-activation watchlist catches them by bundle ID.
/// 2. FRONTMOST-APP AX OBSERVER: sheets (kAXSheetCreated) and windows
///    whose subrole is AXDialog/AXSystemDialog (kAXWindowCreated),
///    re-registered on every app switch. Standard windows and floating
///    panels (Marduk's own palette included) never announce.
///
/// Announcements interrupt reads on purpose — a dialog IS urgent.
/// Main-thread-only (workspace notifications and the AXObserver runloop
/// source both land on main). All logs `[sentinel]`; titles are spoken,
/// never logged (log privacy: titles can carry document names).
final class DialogSentinel {
    /// What announces: .all = system agents AND in-app sheets/dialogs (the
    /// founding behavior, default); .system = only the dedicated system
    /// agents — the central password/permission/alert prompts — for users
    /// who trigger app sheets deliberately and don't need them narrated;
    /// .off = silent.
    enum Level: String {
        case all, system, off
    }

    /// What to focus if the user consents (dialogfocus). Detector 2
    /// retains the dialog's AXUIElement (captured here, so Swift retains
    /// the CF ref); detector 1 has only the agent's PID — its window is
    /// resolved at focus time. Rides WITH the announcement so a
    /// dedup-dropped emission can never leave a stale target behind.
    struct Target {
        let pid: pid_t
        let element: AXUIElement?
    }

    var announce: ((String, Target?) -> Void)?
    var level: Level = .all

    private var workspaceObserver: NSObjectProtocol?
    private var axObserver: AXObserver?
    private var observedPID: pid_t = -1
    private var lastAnnouncement = ""
    private var lastAnnouncedAt = Date.distantPast
    private var suppressSheetsUntil = Date.distantPast

    /// Dialog-serving system processes → what to say when they take focus.
    static let systemAgents: [String: String] = [
        "com.apple.SecurityAgent": "A password prompt needs attention.",
        "com.apple.LocalAuthentication.UIAgent": "An authentication prompt needs attention.",
        "com.apple.UserNotificationCenter": "A system alert needs attention.",
        "com.apple.CoreServicesUIAgent": "A system dialog needs attention.",
    ]

    func start() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.level != .off,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                      as? NSRunningApplication else { return }
            if let bundle = app.bundleIdentifier,
               let message = Self.systemAgents[bundle] {
                fputs("[sentinel] system agent active: \(bundle)\n", stderr)
                self.emit(message,
                          target: Target(pid: app.processIdentifier, element: nil))
            }
            self.observeFrontmost(app)
        }
        if let app = NSWorkspace.shared.frontmostApplication {
            observeFrontmost(app)
        }
        fputs("[sentinel] dialog sentinel started\n", stderr)
    }

    func stop() {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
        teardownAXObserver()
    }

    // MARK: - Frontmost-app AX observation

    private func observeFrontmost(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != observedPID, pid != getpid() else { return }
        teardownAXObserver()
        observedPID = pid

        var observer: AXObserver?
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverCreate(pid, { _, element, notification, refcon in
            guard let refcon else { return }
            let sentinel = Unmanaged<DialogSentinel>.fromOpaque(refcon).takeUnretainedValue()
            sentinel.handleAXNotification(element: element,
                                          notification: notification as String)
        }, &observer) == .success, let observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        AXObserverAddNotification(observer, appElement,
                                  kAXSheetCreatedNotification as CFString, refcon)
        AXObserverAddNotification(observer, appElement,
                                  kAXWindowCreatedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
    }

    private func teardownAXObserver() {
        if let observer = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        axObserver = nil
        observedPID = -1
    }

    /// Marduk sometimes opens sheets itself (the visual-follow go-to-page
    /// gesture in Preview) — announcing our own navigation would be noise.
    /// Suppresses the sheet/dialog detector only; system agents still
    /// announce (a password prompt during a follow window is still urgent).
    func suppress(for seconds: TimeInterval) {
        suppressSheetsUntil = Date().addingTimeInterval(seconds)
    }

    /// Should this overlay be announced, and as what?
    ///
    /// Pure, because it is ~8 lines of judgment behind ~30 lines of AX
    /// plumbing and it has ALREADY shipped one field regression: Qt apps
    /// mass-produce untitled AXDialog windows, and every Packet Tracer
    /// launch false-alarmed "a dialog needs attention".
    ///
    /// Nil = stay silent.
    static func announcement(level: Level, isSheet: Bool, subrole: String,
                             title: String, appName: String,
                             suppressed: Bool) -> String? {
        guard level == .all else { return nil }   // .system keeps app sheets silent
        guard !suppressed else { return nil }     // one of our own sheets
        let isDialog = subrole == "AXDialog" || subrole == "AXSystemDialog"
        guard isSheet || isDialog else { return nil } // standard windows stay silent

        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // An untitled app DIALOG stays silent (the Qt false alarms); real
        // system prompts arrive via the system agents, and SHEETS announce
        // regardless — they are structurally real.
        if isDialog && !isSheet && title.isEmpty { return nil }

        let kind = isSheet ? "sheet" : "dialog"
        return title.isEmpty
            ? "A \(kind) in \(appName) needs attention."
            : "A \(kind) in \(appName): \(title)."
    }

    /// Same text within this window is one announcement — window-created
    /// and sheet-created can fire together, and some apps re-post on focus
    /// cycling.
    static let dedupWindow: TimeInterval = 5

    static func shouldEmit(_ message: String, lastMessage: String?,
                           lastAt: Date, now: Date) -> Bool {
        message != lastMessage || now.timeIntervalSince(lastAt) >= dedupWindow
    }

    private func handleAXNotification(element: AXUIElement, notification: String) {
        var subroleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString,
                                          &subroleRef)
        var titleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString,
                                          &titleRef)
        let isSheet = notification == (kAXSheetCreatedNotification as String)
        let appName = NSRunningApplication(processIdentifier: observedPID)?
            .localizedName ?? "the front app"

        guard let message = Self.announcement(
            level: level, isSheet: isSheet,
            subrole: subroleRef as? String ?? "",
            title: titleRef as? String ?? "", appName: appName,
            suppressed: Date() < suppressSheetsUntil) else { return }

        // Titles are SPOKEN, never logged — the log is pasted into issues
        fputs("[sentinel] \(isSheet ? "sheet" : "dialog") in \(appName)\n", stderr)
        emit(message, target: Target(pid: observedPID, element: element))
    }

    /// Dedup: window-created and sheet-created can fire together, and
    /// some apps re-post on focus cycling — same text within 5s is one
    /// announcement.
    private func emit(_ message: String, target: Target?) {
        let now = Date()
        guard Self.shouldEmit(message, lastMessage: lastAnnouncement,
                              lastAt: lastAnnouncedAt, now: now) else { return }
        lastAnnouncement = message
        lastAnnouncedAt = now
        announce?(message, target)
    }
}
