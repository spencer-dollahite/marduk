import Foundation
import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Display management for bright apps in a dark-mode workflow. Two tools:
///
/// 1. FULL-DISPLAY INVERSION for apps that are hopelessly light (Pages,
///    Packet Tracer): observes foreground app changes and toggles macOS
///    Invert Colors by posting its keyboard shortcut when a configured
///    bundle ID takes the front, reverting the moment it leaves. The
///    shortcut must be enabled in System Settings → Keyboard → Shortcuts →
///    Accessibility (default here: Shift+Cmd+F13, `display.invertShortcut*`
///    overrides).
/// 2. PREVIEW DARK MODE for PDFs: Preview has a per-window "View in Dark
///    Mode" menu item — pressed directly via the AX menu bar (no shortcut
///    needed) whenever Preview comes front or opens a new window, with the
///    menu item's checkmark consulted first so an already-dark window is
///    never toggled back to light. English menu title only (Marduk-wide
///    limitation).
///
/// 3. AUTO-DETECTION (`:config autoinvert`, needs the Screen Recording
///    permission — requested on enable): apps NOT in the list are measured
///    on activation — a 64px ScreenCaptureKit screenshot of the frontmost
///    window, mean channel brightness against `display.autoInvertThreshold`
///    (percent, default 70) — and inverted or reverted accordingly. Listed
///    apps skip the measurement and invert instantly; Preview is skipped
///    when pdfdark handles it. macOS periodically re-confirms screen
///    capture grants — the price of the magic, disclosed in the tip.
///
/// Everything defaults OFF/empty — visual surprises make terrible first
/// impressions — and applies live via `:config invert` / `:config pdfdark`
/// / `:config autoinvert`.
// @unchecked Sendable: the codebase's standard workaround — the brightness
// Task hops off-main; mutable state it touches is a threshold read and a
// log-once flag, and all decisions re-enter main before acting.
final class DisplayInverter: @unchecked Sendable {
    var invertApps: Set<String>
    var invertEnabled = true
    var previewDarkMode = false
    var autoInvert = false
    /// Mean-brightness threshold, 0…1 (config carries percent).
    var autoInvertThreshold = 0.70
    private var captureFailureLogged = false

    private var isInverted = false
    private var observer: NSObjectProtocol?
    private var previewObserver: AXObserver?
    private var previewObserverPID: pid_t = -1

    // Same marker used by KeyboardMonitor so the event tap passes these through
    private static let syntheticMarker: Int64 = 0x4D52444B // "MRDK"

    static let previewBundle = "com.apple.Preview"

    init(invertApps: [String]) {
        self.invertApps = Set(invertApps)
    }

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            self?.handleAppActivated(bundleID, pid: app.processIdentifier)
        }

        // Check current foreground app immediately (handles daemon restart)
        if let app = NSWorkspace.shared.frontmostApplication,
           let bundleID = app.bundleIdentifier {
            handleAppActivated(bundleID, pid: app.processIdentifier)
        }

        fputs("[display] tracking started (\(invertApps.count) invert app(s), "
            + "Preview dark mode \(previewDarkMode ? "on" : "off"))\n", stderr)
    }

    func stop() {
        if let observer = observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        teardownPreviewObserver()
        // Revert inversion if active
        if isInverted {
            toggleInversion()
            isInverted = false
            fputs("[display] Reverted inversion on stop\n", stderr)
        }
    }

    /// Live `:config invert off` mid-invert must hand the display back.
    func revertIfInverted() {
        if isInverted {
            toggleInversion()
            isInverted = false
            fputs("[display] Reverted inversion (invert off)\n", stderr)
        }
    }

    /// Force TCC registration: a capture attempt makes Marduk appear in
    /// the Screen Recording privacy pane even when macOS shows no dialog
    /// (modern macOS often registers silently instead of prompting).
    func primeCapturePermission() {
        Task {
            _ = try? await SCShareableContent
                .excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
    }

    /// Live `:config pdfdark on` with Preview already front applies now.
    func applyPreviewDarkModeIfFront() {
        guard previewDarkMode,
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == Self.previewBundle else { return }
        applyPreviewDarkMode(pid: app.processIdentifier)
        observePreviewWindows(pid: app.processIdentifier)
    }

    private func handleAppActivated(_ bundleID: String, pid: pid_t) {
        if invertEnabled {
            // Measurement OVERRIDES the list when auto is on: a Pages deck
            // the user styled black-on-white-text must not be inverted into
            // glare just because Pages is listed. The list alone (auto off)
            // stays unconditional — instant, no capture permission needed.
            if autoInvert, bundleID != Self.previewBundle || !previewDarkMode,
               bundleID != Bundle.main.bundleIdentifier {
                evaluateBrightness(bundleID: bundleID, pid: pid)
            } else if invertApps.contains(bundleID) {
                ensureInverted(true, reason: bundleID)
            } else {
                ensureInverted(false, reason: "left invert app")
            }
        }

        if bundleID == Self.previewBundle {
            if previewDarkMode {
                applyPreviewDarkMode(pid: pid)
                observePreviewWindows(pid: pid)
            }
        } else {
            teardownPreviewObserver()
        }
    }

    private func ensureInverted(_ wanted: Bool, reason: String) {
        guard wanted != isInverted else { return }
        toggleInversion()
        isInverted = wanted
        fputs("[display] \(wanted ? "Inverted" : "Reverted") (\(reason))\n", stderr)
    }

    // MARK: - Brightness auto-detection

    /// One tiny screenshot of the app's frontmost window, mean brightness,
    /// invert/revert decision — guarded so a slow capture landing after
    /// another app switch changes nothing.
    private func evaluateBrightness(bundleID: String, pid: pid_t) {
        Task { [weak self] in
            guard let self else { return }
            var measured: Double?
            do {
                let content = try await SCShareableContent
                    .excludingDesktopWindows(false, onScreenWindowsOnly: true)
                // LARGEST window, not first — an activation that comes with
                // a small dialog up must still measure the document window
                guard let window = content.windows
                    .filter({ $0.owningApplication?.processID == pid && $0.isOnScreen
                                && $0.frame.width > 200 && $0.frame.height > 150 })
                    .max(by: { $0.frame.width * $0.frame.height
                             < $1.frame.width * $1.frame.height }) else { return }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                config.width = 64
                config.height = 40
                config.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config)
                measured = Self.meanBrightness(image)
            } catch {
                if !self.captureFailureLogged {
                    self.captureFailureLogged = true
                    fputs("[display] auto-invert capture failed (Screen Recording "
                        + "permission?): \(error.localizedDescription)\n", stderr)
                }
                return
            }
            guard let measured else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.invertEnabled, self.autoInvert,
                      NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                          == bundleID else { return }
                // The capture sees the screen AS DISPLAYED — including our
                // own inversion (field-diagnosed: invert → next measurement
                // reads dark → revert → oscillation). Inversion is exactly
                // 255−x per channel, so undo it in the math, and keep a
                // deadband so boundary values can't flap on re-measures.
                let effective = self.isInverted ? 1 - measured : measured
                let wanted: Bool
                if self.isInverted {
                    wanted = effective > self.autoInvertThreshold - 0.08
                } else {
                    wanted = effective > self.autoInvertThreshold
                }
                self.ensureInverted(wanted,
                                    reason: "auto \(bundleID) "
                                        + String(format: "%.2f", effective))
            }
        }
    }

    /// Mean of the color channels across the image, 0…1. Channel-order
    /// agnostic on purpose (BGRA vs RGBA doesn't matter to a mean), which
    /// is plenty for a bright-or-dark verdict.
    static func meanBrightness(_ image: CGImage) -> Double? {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let bytesPerPixel = image.bitsPerPixel / 8
        guard bytesPerPixel >= 3, image.bitsPerComponent == 8 else { return nil }
        let alphaFirst = image.alphaInfo == .premultipliedFirst
            || image.alphaInfo == .first || image.alphaInfo == .noneSkipFirst
        let colorOffset = alphaFirst && bytesPerPixel == 4 ? 1 : 0
        var total = 0
        var samples = 0
        for y in 0..<image.height {
            let row = y * image.bytesPerRow
            for x in 0..<image.width {
                let p = row + x * bytesPerPixel + colorOffset
                total += Int(bytes[p]) + Int(bytes[p + 1]) + Int(bytes[p + 2])
                samples += 3
            }
        }
        guard samples > 0 else { return nil }
        return Double(total) / Double(samples) / 255.0
    }

    /// Posts the system Invert Colors shortcut (default Shift+Cmd+F13,
    /// keycode 105 — configure the same chord in System Settings →
    /// Keyboard → Shortcuts → Accessibility → Invert colors).
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

    // MARK: - Preview "View in Dark Mode"

    /// Press View → View in Dark Mode via the AX menu bar when the focused
    /// window isn't already dark (AXMenuItemMarkChar carries the checkmark).
    /// Off-main: menu walks are synchronous AX IPC.
    private func applyPreviewDarkMode(pid: pid_t) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.3)

            var menuBarRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                      app, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
                  let rawBar = menuBarRef,
                  CFGetTypeID(rawBar) == AXUIElementGetTypeID() else { return }

            // Titles shift across macOS releases — search the whole menu
            // bar for anything containing "dark mode" instead of pinning
            // one exact string (still English-only, a Marduk-wide limit)
            guard let item = Self.findMenuItem(containing: "dark mode",
                                               under: rawBar as! AXUIElement,
                                               depth: 6) else {
                let viewCount = Self.child(of: rawBar as! AXUIElement, titled: "View")
                    .map { Self.children(of: $0).first.map { Self.children(of: $0).count } ?? 0 }
                fputs("[display] Preview dark: no dark-mode menu item "
                    + "(View menu items: \(viewCount ?? -1))\n", stderr)
                return
            }

            var markRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(
                item, "AXMenuItemMarkChar" as CFString, &markRef)
            if let mark = markRef as? String, !mark.isEmpty {
                return  // already dark — pressing would toggle it back
            }
            if AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
                fputs("[display] Preview dark: applied\n", stderr)
            } else {
                fputs("[display] Preview dark: press failed\n", stderr)
            }
        }
    }

    /// Windows opened while Preview is already front (double-clicking a
    /// second PDF) need the treatment too — the sentinel pattern, scoped
    /// to Preview.
    private func observePreviewWindows(pid: pid_t) {
        guard pid != previewObserverPID else { return }
        teardownPreviewObserver()

        var observer: AXObserver?
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let inverter = Unmanaged<DisplayInverter>.fromOpaque(refcon).takeUnretainedValue()
            guard inverter.previewDarkMode else { return }
            inverter.applyPreviewDarkMode(pid: inverter.previewObserverPID)
        }, &observer) == .success, let observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        AXObserverAddNotification(observer, appElement,
                                  kAXWindowCreatedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(observer), .defaultMode)
        previewObserver = observer
        previewObserverPID = pid
    }

    private func teardownPreviewObserver() {
        if let observer = previewObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        previewObserver = nil
        previewObserverPID = -1
    }

    // MARK: - AX helpers

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, kAXChildrenAttribute as CFString, &ref) == .success,
              let children = ref as? [AXUIElement] else { return [] }
        return children
    }

    /// Depth-limited search of a menu tree for an item whose title
    /// contains `needle` (case-insensitive).
    private static func findMenuItem(containing needle: String,
                                     under element: AXUIElement,
                                     depth: Int) -> AXUIElement? {
        guard depth > 0 else { return nil }
        for child in children(of: element) {
            var titleRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString,
                                              &titleRef)
            if let title = titleRef as? String,
               title.lowercased().contains(needle) {
                return child
            }
            if let found = findMenuItem(containing: needle, under: child,
                                        depth: depth - 1) {
                return found
            }
        }
        return nil
    }

    private static func child(of element: AXUIElement, titled title: String) -> AXUIElement? {
        children(of: element).first { child in
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                      child, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let t = titleRef as? String else { return false }
            return t == title
        }
    }
}
