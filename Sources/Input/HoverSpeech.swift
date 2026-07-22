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
/// Dwell model: the pointer is POLLED (NSEvent.mouseLocation, ~8Hz,
/// only while active); when it settles somewhere new, the element under
/// it is fetched (AX element-at-position) and its NAME is spoken —
/// title, else description, else value — minimal verbosity by design
/// ("Submit", not "Submit, button, in toolbar"). Same element or same
/// label repeats stay silent. Marduk's own windows are skipped.
/// Main-thread-only.
///
/// Polling, not events, ON PURPOSE (field 2026-07-22): the original
/// NSEvent global mouse-move monitor INSTALLED cleanly and then
/// delivered ZERO events to the background daemon — hover spoke once at
/// toggle time and went deaf to movement. Reading the pointer position
/// is permission-free and has no delivery path to break; a dwell
/// feature only needs "has the pointer settled somewhere new". Do not
/// switch back to NSEvent monitors or add a second event tap for this.
final class HoverSpeech {
    var speak: ((String) -> Void)?      // → SpeechEngine.hover (echo channel)
    var announce: ((String) -> Void)?   // toggle feedback
    private(set) var active = false

    private var pollTimer: Timer?
    private var lastPoint = NSPoint(x: -1, y: -1)
    private var settledSince = Date()
    private var spokenAtRest = true
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
        lastPoint = NSEvent.mouseLocation
        settledSince = Date()
        spokenAtRest = true  // the immediate speak below covers this rest
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        fputs("[keyboard] hover: pointer polling started\n", stderr)
        speakUnderPointer() // whatever it's already on speaks immediately
    }

    /// Public: teardown and Ctrl+Option+M disable also land here.
    func deactivate() {
        active = false
        pollTimer?.invalidate()
        pollTimer = nil
        lastElement = nil
        lastLabel = ""
        fputs("[keyboard] hover session: \(movedEvents) movements, "
            + "\(dwellFires) dwells, \(spokeCount) spoken, "
            + "\(skipSameElement) same-element, \(skipSameLabel) same-label, "
            + "\(skipNoLabel) unlabeled, \(axFailures) AX failures, "
            + "\(skipOwnWindow) own-window\n", stderr)
    }

    /// One poll tick: movement resets the dwell clock; a pointer that
    /// has settled somewhere new for ~0.3s speaks once. Slow deliberate
    /// gliding (under the movement threshold) counts as settled — a
    /// low-vision user creeping across a toolbar WANTS the names.
    private func poll() {
        guard active else { return }
        let p = NSEvent.mouseLocation
        if abs(p.x - lastPoint.x) > 3 || abs(p.y - lastPoint.y) > 3 {
            movedEvents += 1
            if movedEvents == 1 {
                fputs("[keyboard] hover: first movement detected\n", stderr)
            }
            lastPoint = p
            settledSince = Date()
            spokenAtRest = false
            return
        }
        lastPoint = p
        if !spokenAtRest, Date().timeIntervalSince(settledSince) >= 0.3 {
            spokenAtRest = true
            speakUnderPointer()
        }
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
