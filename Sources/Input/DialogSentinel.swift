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

    var announce: ((String) -> Void)?
    var level: Level = .all

    private var workspaceObserver: NSObjectProtocol?
    private var axObserver: AXObserver?
    private var observedPID: pid_t = -1
    private var lastAnnouncement = ""
    private var lastAnnouncedAt = Date.distantPast

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
                self.emit(message)
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

    private func handleAXNotification(element: AXUIElement, notification: String) {
        guard level == .all else { return }  // .system keeps app sheets silent
        var subroleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString,
                                          &subroleRef)
        let subrole = subroleRef as? String ?? ""

        let isSheet = notification == (kAXSheetCreatedNotification as String)
        let isDialog = subrole == "AXDialog" || subrole == "AXSystemDialog"
        guard isSheet || isDialog else { return } // standard windows stay silent

        var titleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString,
                                          &titleRef)
        let title = (titleRef as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let appName = NSRunningApplication(processIdentifier: observedPID)?
            .localizedName ?? "the front app"

        let kind = isSheet ? "sheet" : "dialog"
        let message = title.isEmpty
            ? "A \(kind) in \(appName) needs attention."
            : "A \(kind) in \(appName): \(title)."
        fputs("[sentinel] \(kind) in \(appName) (title \(title.count) chars)\n", stderr)
        emit(message)
    }

    /// Dedup: window-created and sheet-created can fire together, and
    /// some apps re-post on focus cycling — same text within 5s is one
    /// announcement.
    private func emit(_ message: String) {
        let now = Date()
        if message == lastAnnouncement,
           now.timeIntervalSince(lastAnnouncedAt) < 5 { return }
        lastAnnouncement = message
        lastAnnouncedAt = now
        announce?(message)
    }
}
