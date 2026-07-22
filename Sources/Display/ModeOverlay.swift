import AppKit

/// Full-screen, click-through visual mode indicator: a thick colored border
/// at the screen edges and/or a small colored dot that follows the mouse
/// pointer. Red = NORMAL, green = INSERT, blue = VISUAL, purple = READING
/// capture (overrides the mode color), nothing = Marduk off (colors
/// configurable; "none" hides a mode). BOTH OFF by default —
/// enable with `:config border on` / `:config pointer on` or the `overlay`
/// block in config.json.
///
/// The pointer dot exists because macOS fullscreen zoom magnifies the
/// composited framebuffer — overlay windows included — and there is no
/// public API for the zoomed viewport, so the edge border can be entirely
/// out of view while zoomed in. The pointer, which zoom tracks, never is.
///
/// Rendering is pure CALayer properties (borderWidth/borderColor/
/// backgroundColor) — no draw(_:) rasterization, so a mode flip is a cheap
/// GPU property commit instead of a full-screen redraw per display.
///
/// All window work happens on the main queue; setMode/setEnabled may be
/// called from the event-tap callback (they only dispatch, never block).
final class ModeOverlay {
    private struct Style {
        let borderEnabled: Bool
        let pointerEnabled: Bool
        let thickness: CGFloat
        let pointerSize: CGFloat
        let normalColor: NSColor?
        let insertColor: NSColor?
        let visualColor: NSColor?
        let readingColor: NSColor?
    }

    private let style: Style
    private var borderWindows: [NSWindow] = []
    private var pointerWindow: NSWindow?
    private var mouseMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var currentMode: KeyboardMonitor.Mode = .normal
    private var reading = false   // READING capture overrides the mode color
    private var mardukEnabled = true
    private var started = false

    // Skip redundant apply() work (typing rescue flips modes frequently, and
    // screen-parameter notifications can fire in storms during resolution
    // changes). hasApplied is cleared on window rebuild so fresh windows
    // always get colored and ordered in.
    private var appliedColor: NSColor?
    private var hasApplied = false

    /// Returns nil when both indicators are disabled in config (the
    /// default). Config fields are Optional (partial hand-edited blocks must
    /// decode) — defaults live here.
    init?(config: MardukConfig.OverlayConfig) {
        let borderEnabled = config.borderEnabled ?? false
        let pointerEnabled = config.pointerEnabled ?? false
        guard borderEnabled || pointerEnabled else { return nil }
        style = Style(
            borderEnabled: borderEnabled,
            pointerEnabled: pointerEnabled,
            thickness: CGFloat(max(1, config.thickness ?? 6)),
            pointerSize: CGFloat(max(8, config.pointerSize ?? 28)),
            normalColor: Self.parseColor(config.normalColor ?? "#FF3B30"),
            insertColor: Self.parseColor(config.insertColor ?? "#34C759"),
            visualColor: Self.parseColor(config.visualColor ?? "#007AFF"),
            readingColor: Self.parseColor(config.readingColor ?? "#AF52DE")
        )
    }

    func start() {
        DispatchQueue.main.async { [self] in
            guard !started else { return }
            started = true

            if style.borderEnabled {
                rebuildBorderWindows()
                // Displays come and go (external monitor, resolution change)
                screenObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification,
                    object: nil, queue: .main
                ) { [weak self] _ in
                    self?.rebuildBorderWindows()
                    self?.apply()
                }
            }

            if style.pointerEnabled {
                let size = style.pointerSize
                let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
                view.wantsLayer = true
                view.layer?.cornerRadius = size / 2
                view.layer?.borderWidth = 2
                view.layer?.borderColor = NSColor.black.withAlphaComponent(0.6).cgColor
                pointerWindow = Self.makeOverlayWindow(
                    frame: NSRect(origin: .zero, size: NSSize(width: size, height: size)),
                    view: view
                )
                // Global monitors don't fire for our own windows and need
                // Accessibility permission, which Marduk already has
                mouseMonitor = NSEvent.addGlobalMonitorForEvents(
                    matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
                ) { [weak self] _ in
                    // No work while hidden — this fires at pointer-motion
                    // rate on the same main thread as the event tap
                    guard let self, self.pointerWindow?.isVisible == true else { return }
                    self.positionPointerWindow()
                }
            }

            apply()
            fputs("[overlay] mode overlay started (border: \(style.borderEnabled), pointer: \(style.pointerEnabled))\n", stderr)
        }
    }

    func stop() {
        DispatchQueue.main.async { [self] in
            guard started else { return }
            started = false
            if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor) }
            mouseMonitor = nil
            if let observer = screenObserver { NotificationCenter.default.removeObserver(observer) }
            screenObserver = nil
            for win in borderWindows { win.orderOut(nil) }
            borderWindows = []
            pointerWindow?.orderOut(nil)
            pointerWindow = nil
        }
    }

    func setMode(_ mode: KeyboardMonitor.Mode) {
        DispatchQueue.main.async { [self] in
            currentMode = mode
            apply()
        }
    }

    func setEnabled(_ enabled: Bool) {
        DispatchQueue.main.async { [self] in
            mardukEnabled = enabled
            apply()
        }
    }

    /// READING capture (read motions): purple while a read owns the
    /// keyboard, whatever mode sits underneath.
    func setReading(_ reading: Bool) {
        DispatchQueue.main.async { [self] in
            self.reading = reading
            apply()
        }
    }

    // MARK: - Internals (main thread only)

    private func apply() {
        guard started else { return }
        let modeColor = reading ? style.readingColor : color(for: currentMode)
        let activeColor = mardukEnabled ? modeColor : nil
        if hasApplied, activeColor == appliedColor { return }
        hasApplied = true
        appliedColor = activeColor

        if let activeColor {
            let cgColor = activeColor.cgColor
            for win in borderWindows {
                win.contentView?.layer?.borderColor = cgColor
                win.orderFrontRegardless()
            }
            if let win = pointerWindow {
                win.contentView?.layer?.backgroundColor = cgColor
                positionPointerWindow() // may have gone stale while hidden
                win.orderFrontRegardless()
            }
        } else {
            for win in borderWindows { win.orderOut(nil) }
            pointerWindow?.orderOut(nil)
        }
    }

    private func color(for mode: KeyboardMonitor.Mode) -> NSColor? {
        switch mode {
        case .normal: return style.normalColor
        case .insert: return style.insertColor
        case .visual, .visualLine: return style.visualColor
        // COMMAND is a transient over NORMAL and returns there; the palette
        // is its own visual indicator, so the border stays on normal's color
        case .command: return style.normalColor
        }
    }

    private func rebuildBorderWindows() {
        for win in borderWindows { win.orderOut(nil) }
        borderWindows = NSScreen.screens.map { screen in
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            view.layer?.borderWidth = style.thickness
            return Self.makeOverlayWindow(frame: screen.frame, view: view)
        }
        hasApplied = false // fresh windows need color + ordering
    }

    private func positionPointerWindow() {
        guard let win = pointerWindow else { return }
        // NSEvent.mouseLocation is global bottom-left-origin, same space as
        // setFrameOrigin. Offset up-right so the dot doesn't sit under the
        // click point.
        let loc = NSEvent.mouseLocation
        win.setFrameOrigin(NSPoint(x: loc.x + 14, y: loc.y + 14))
    }

    private static func makeOverlayWindow(frame: NSRect, view: NSView) -> NSWindow {
        let win = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        // .screenSaver is safe here (unlike the palette, which takes key
        // focus and broke zoom at this level) — these windows never take focus
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.isReleasedWhenClosed = false
        win.contentView = view
        return win
    }

    /// "#RRGGBB" → NSColor; "" or "none" → nil (mode shows nothing).
    /// `#RRGGBB` → a color; `""` or `"none"` → nil, meaning that mode
    /// shows NOTHING. Internal so a test can pin it: a parse regression
    /// makes a mode invisible, and telling NORMAL from INSERT at a glance
    /// is the overlay's entire job.
    static func parseColor(_ raw: String) -> NSColor? {
        var hex = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if hex.isEmpty || hex == "none" { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else {
            fputs("[overlay] bad color \"\(raw)\" — expected #RRGGBB or \"none\"\n", stderr)
            return nil
        }
        return NSColor(
            red: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
