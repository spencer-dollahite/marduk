import Foundation
import AppKit
import ApplicationServices

/// Observes foreground app changes and toggles display inversion
/// for configured bundle IDs by posting Shift+Cmd+F13.
final class DisplayInverter {
    private let invertApps: Set<String>
    private var isInverted = false
    private var observer: NSObjectProtocol?

    // Same marker used by KeyboardMonitor so the event tap passes these through
    private static let syntheticMarker: Int64 = 0x4D52444B // "MRDK"

    init(invertApps: [String]) {
        self.invertApps = Set(invertApps)
    }

    func start() {
        guard !invertApps.isEmpty else { return }

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            self?.handleAppActivated(bundleID)
        }

        // Check current foreground app immediately (handles daemon restart)
        if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            handleAppActivated(bundleID)
        }

        fputs("[display] Invert tracking started for \(invertApps.count) app(s)\n", stderr)
    }

    func stop() {
        if let observer = observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        // Revert inversion if active
        if isInverted {
            toggleInversion()
            isInverted = false
            fputs("[display] Reverted inversion on stop\n", stderr)
        }
    }

    private func handleAppActivated(_ bundleID: String) {
        let shouldInvert = invertApps.contains(bundleID)

        if shouldInvert && !isInverted {
            toggleInversion()
            isInverted = true
            fputs("[display] Inverted for \(bundleID)\n", stderr)
        } else if !shouldInvert && isInverted {
            toggleInversion()
            isInverted = false
            fputs("[display] Reverted inversion (left invert app)\n", stderr)
        }
    }

    /// Posts Shift+Cmd+F13 (keycode 105) to toggle display inversion.
    private func toggleInversion() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keycode: CGKeyCode = 105 // F13

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: false) else { return }

        let flags: CGEventFlags = [.maskShift, .maskCommand]

        down.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        down.post(tap: .cghidEventTap)

        up.flags = flags
        up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        up.post(tap: .cghidEventTap)
    }
}
