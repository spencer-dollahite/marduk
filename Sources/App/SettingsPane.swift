import Foundation
import AppKit
import ApplicationServices

/// System Settings deep links that actually land INSIDE the section.
///
/// `x-apple.systempreferences:` URLs only reliably reach a PANE. The
/// legacy per-section anchors (`?SpeakSelectedText`) stopped navigating
/// somewhere in the System Settings rewrite, so `:pronunciation` dumped
/// the user on the Accessibility LIST with the section they wanted one
/// unseen row away — useless to someone who can't spot it (field
/// 2026-07-23). A URL guess can't be verified either: System Settings
/// swallows any anchor and `open` exits 0 regardless, so a ladder of
/// candidate URLs would fail silently.
///
/// The fix is the pattern Preview's dark-appearance press already uses:
/// open the pane by URL, then find the section ROW BY NAME in the AX tree
/// and press it. Names are DATA (`rowTitles`) — a rename ("Spoken
/// Content" → "Read & Speak Content") or a new destination costs a
/// string, not a code path. Self-correcting: if the URL ever does land
/// inside the section, no matching row exists and nothing is pressed.
/// English-only, a Marduk-wide limit.
enum SettingsPane {
    private static let bundleID = "com.apple.systempreferences"

    /// Poll budget for System Settings to launch and draw its pane.
    private static let deadline: TimeInterval = 6
    private static let pollInterval: TimeInterval = 0.3

    /// Accessibility > Read & Speak Content — where the system
    /// pronunciation editor and the typing feedback switches live, and
    /// the destination of both `:pronunciation` and `:typing`. The row
    /// has been renamed across releases ("Speech" → "Spoken Content" →
    /// "Read & Speak Content" on macOS 26), so every name it has worn is
    /// listed; the first one present wins.
    static let readAndSpeakNames = ["read & speak", "read and speak",
                                    "spoken content"]

    static func openReadAndSpeakContent() {
        Self.open("x-apple.systempreferences:com.apple.preference.universalaccess"
                     + "?SpeakSelectedText",
                  thenSelect: readAndSpeakNames)
    }

    /// Open `url`, then navigate into the first section row whose name
    /// contains any of `rowTitles` (case-insensitive). Returns immediately;
    /// the descent runs off-main.
    static func open(_ url: String, thenSelect rowTitles: [String] = []) {
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = [url]
        try? opener.run()
        guard !rowTitles.isEmpty else { return }
        // AX is synchronous IPC and this polls for seconds — never on the
        // main thread, which drives the event tap.
        DispatchQueue.global(qos: .utility).async { Self.descend(into: rowTitles) }
    }

    /// True when `text` carries any needle. Pure — the whole match rule.
    static func matches(_ text: String, _ needles: [String]) -> Bool {
        let haystack = text.lowercased()
        return needles.contains { haystack.contains($0.lowercased()) }
    }

    // MARK: - AX descent

    private static func descend(into needles: [String]) {
        let stopBy = Date().addingTimeInterval(deadline)
        while Date() < stopBy {
            Thread.sleep(forTimeInterval: pollInterval)
            guard let app = NSRunningApplication
                    .runningApplications(withBundleIdentifier: bundleID).first,
                  !app.isTerminated else { continue }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.3)

            var windowRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                      element, kAXFocusedWindowAttribute as CFString,
                      &windowRef) == .success,
                  let raw = windowRef,
                  CFGetTypeID(raw) == AXUIElementGetTypeID() else { continue }

            guard let row = find(needles, under: raw as! AXUIElement, depth: 14)
            else { continue }
            if press(row) {
                fputs("[command] settings: section row pressed\n", stderr)
            } else {
                fputs("[command] settings: section row found but nothing "
                    + "along its ancestry accepts a press\n", stderr)
            }
            return
        }
        fputs("[command] settings: no section row within \(Int(deadline))s "
            + "— pane only\n", stderr)
    }

    /// Depth-limited search for the element naming the section. A row's
    /// name can arrive as its title, its description, or — for the
    /// AXStaticText labels SwiftUI lists are built from — its value.
    private static func find(_ needles: [String], under element: AXUIElement,
                             depth: Int) -> AXUIElement? {
        guard depth > 0 else { return nil }
        for child in children(of: element) {
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute,
                              kAXValueAttribute] {
                var ref: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                          child, attribute as CFString, &ref) == .success,
                      let text = ref as? String, matches(text, needles)
                else { continue }
                return child
            }
            if let found = find(needles, under: child, depth: depth - 1) {
                return found
            }
        }
        return nil
    }

    /// Press the row: the naming element itself when it takes a press,
    /// else the nearest ancestor that does (the label is usually a leaf
    /// inside the pressable cell). Bounded to 3 levels and to
    /// row-shaped roles, so a miss can never press the whole window.
    private static func press(_ element: AXUIElement) -> Bool {
        var candidate: AXUIElement? = element
        for level in 0..<4 {
            guard let current = candidate else { return false }
            if level == 0 || isRowShaped(current),
               actions(of: current).contains(kAXPressAction),
               AXUIElementPerformAction(current,
                                        kAXPressAction as CFString) == .success {
                return true
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                      current, kAXParentAttribute as CFString,
                      &parentRef) == .success,
                  let raw = parentRef,
                  CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
            candidate = (raw as! AXUIElement)
        }
        return false
    }

    private static func isRowShaped(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, kAXRoleAttribute as CFString, &ref) == .success,
              let role = ref as? String else { return false }
        return [kAXButtonRole, kAXRowRole, kAXCellRole, kAXGroupRole,
                kAXStaticTextRole, kAXLinkRole].contains(role)
    }

    private static func actions(of element: AXUIElement) -> [String] {
        var ref: CFArray?
        guard AXUIElementCopyActionNames(element, &ref) == .success,
              let names = (ref as NSArray?) as? [String] else { return [] }
        return names
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, kAXChildrenAttribute as CFString, &ref) == .success,
              let children = ref as? [AXUIElement] else { return [] }
        return children
    }
}
