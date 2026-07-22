import Foundation
import AppKit
import ApplicationServices

/// Marduk-native "speak item under pointer" — replaces the macOS hover
/// feature the `s` command used to trigger, so hover speech uses the
/// user's OWN reading voice, rate, and pitch instead of the system
/// engine's separately-configured one (the eternal voice-mismatch
/// complaint). No Settings shortcut setup, no media pausing — labels
/// are short and ride the echo channel, never disturbing a read.
///
/// Dwell model: pointer movement arms a short timer; when the pointer
/// settles, the element under it is fetched (AX element-at-position)
/// and its NAME is spoken — title, else description, else value —
/// minimal verbosity by design ("Submit", not "Submit, button, in
/// toolbar"). Same element or same label repeats stay silent. Marduk's
/// own windows are skipped. Main-thread-only.
final class HoverSpeech {
    var speak: ((String) -> Void)?      // → SpeechEngine.hover (echo channel)
    var announce: ((String) -> Void)?   // toggle feedback
    private(set) var active = false

    private var mouseMonitor: Any?
    private var dwellTimer: DispatchWorkItem?
    private var lastLabel = ""
    private var lastElement: AXUIElement?

    // Field diagnostics (2026-07-22 report: spoke once at toggle, then
    // went silent). The whole pipeline was log-invisible — a dead session
    // and a healthy one looked identical — so every stage now counts,
    // first occurrences log, and deactivate prints the tally. Privacy:
    // counts, AX error codes, and label LENGTHS only, never content.
    private var movedEvents = 0
    private var dwellFires = 0
    private var axFailures = 0
    private var skipOwnWindow = 0
    private var skipSameElement = 0
    private var skipNoLabel = 0
    private var skipSameLabel = 0
    private var spokeCount = 0

    func toggle() {
        if active { deactivate() } else { activate() }
        fputs("[keyboard] s → pointer speech \(active ? "on" : "off")\n", stderr)
        announce?(active ? "Pointer speech on." : "Pointer speech off.")
    }

    private func activate() {
        active = true
        movedEvents = 0; dwellFires = 0; axFailures = 0
        skipOwnWindow = 0; skipSameElement = 0; skipNoLabel = 0
        skipSameLabel = 0; spokeCount = 0
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] _ in
            self?.pointerMoved()
        }
        // A nil monitor is a MISSING PERMISSION (NSEvent global monitors
        // return nil ungranted) — the exact "speaks once at toggle, then
        // dead to movement" failure: the immediate speak below still
        // works, movement never arrives.
        fputs(mouseMonitor == nil
            ? "[keyboard] hover: mouse monitor FAILED — permission missing?\n"
            : "[keyboard] hover: mouse monitor installed\n", stderr)
        speakUnderPointer() // whatever it's already on speaks immediately
    }

    /// Public: teardown and Ctrl+Option+M disable also land here.
    func deactivate() {
        active = false
        if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor) }
        mouseMonitor = nil
        dwellTimer?.cancel()
        lastElement = nil
        lastLabel = ""
        fputs("[keyboard] hover session: \(movedEvents) moves, "
            + "\(dwellFires) dwells, \(spokeCount) spoken, "
            + "\(skipSameElement) same-element, \(skipSameLabel) same-label, "
            + "\(skipNoLabel) unlabeled, \(axFailures) AX failures, "
            + "\(skipOwnWindow) own-window\n", stderr)
    }

    private func pointerMoved() {
        movedEvents += 1
        if movedEvents == 1 {
            fputs("[keyboard] hover: first move event arrived\n", stderr)
        }
        dwellTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.speakUnderPointer() }
        dwellTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func speakUnderPointer() {
        guard active else { return }
        dwellFires += 1
        let mouse = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        var elementRef: AXUIElement?
        let axErr = AXUIElementCopyElementAtPosition(
            systemWide, Float(mouse.x), Float(primaryHeight - mouse.y), &elementRef)
        guard axErr == .success, let element = elementRef else {
            axFailures += 1
            if axFailures == 1 {
                fputs("[keyboard] hover: element-at-position failed "
                    + "(\(axErr.rawValue))\n", stderr)
            }
            return
        }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != getpid() else { // never narrate our own overlay
            skipOwnWindow += 1
            return
        }

        if let last = lastElement, CFEqual(last, element) {
            skipSameElement += 1
            if skipSameElement == 1 {
                fputs("[keyboard] hover: dwell hit the same element "
                    + "(dedup working, or the app hit-tests coarsely)\n", stderr)
            }
            return
        }
        lastElement = element
        AXUIElementSetMessagingTimeout(element, 0.25)

        func attribute(_ name: String) -> String? {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                      element, name as CFString, &ref) == .success else { return nil }
            if let string = ref as? String { return string }
            if let number = ref as? NSNumber { return number.stringValue }
            return nil
        }

        // Minimal verbosity, per the project's founding rule: the name,
        // nothing else. Title beats description beats value.
        var label = attribute(kAXTitleAttribute as String) ?? ""
        if label.isEmpty { label = attribute("AXDescription") ?? "" }
        if label.isEmpty { label = attribute(kAXValueAttribute as String) ?? "" }
        label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.count > 160 { label = String(label.prefix(160)) }
        guard !label.isEmpty else {
            skipNoLabel += 1
            if skipNoLabel == 1 {
                let role = attribute(kAXRoleAttribute as String) ?? "?"
                fputs("[keyboard] hover: unlabeled element (role \(role))\n", stderr)
            }
            return
        }
        guard label != lastLabel else {
            skipSameLabel += 1
            return
        }
        lastLabel = label
        spokeCount += 1
        fputs("[keyboard] hover: speaking (\(label.count) chars)\n", stderr)
        speak?(label)
    }
}
