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

    func toggle() {
        if active { deactivate() } else { activate() }
        fputs("[keyboard] s → pointer speech \(active ? "on" : "off")\n", stderr)
        announce?(active ? "Pointer speech on." : "Pointer speech off.")
    }

    private func activate() {
        active = true
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] _ in
            self?.pointerMoved()
        }
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
    }

    private func pointerMoved() {
        dwellTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.speakUnderPointer() }
        dwellTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func speakUnderPointer() {
        guard active else { return }
        let mouse = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        var elementRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
                  systemWide,
                  Float(mouse.x), Float(primaryHeight - mouse.y),
                  &elementRef
              ) == .success,
              let element = elementRef else { return }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != getpid() else { return } // never narrate our own overlay

        if let last = lastElement, CFEqual(last, element) { return }
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
        guard !label.isEmpty, label != lastLabel else { return }
        lastLabel = label
        speak?(label)
    }
}
