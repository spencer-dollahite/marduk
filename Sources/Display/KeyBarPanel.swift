import AppKit

/// A one-line, terminal-styled key-help bar — Marduk's OWN replacement
/// for newsboat's keymap hints (which are hidden via `show-keymap-hint
/// no` in the managed config, and would list NEWSBOAT's bindings, not
/// Marduk's). Sits bottom-center of the pointer's screen; display-only:
/// never key, never activating, ignores the mouse entirely. The text
/// swaps as the mode changes (list / raw control / reading), so it also
/// answers "who owns the keyboard right now" at a glance.
final class KeyBarPanel {

    private var panel: NSPanel?
    private var field: NSTextField?
    private var isShown = false
    private let barHeight: CGFloat = 28
    private let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    func show(_ text: String) {
        DispatchQueue.main.async { [self] in render(text) }
    }

    func hide() {
        DispatchQueue.main.async { [self] in
            guard isShown else { return }
            isShown = false
            panel?.orderOut(nil)
        }
    }

    // MARK: - Rendering (main thread only)

    private func render(_ text: String) {
        let (panel, field) = ensurePanel()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]
        field.attributedStringValue = NSAttributedString(string: text,
                                                         attributes: attributes)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let textWidth = (text as NSString).size(withAttributes: attributes).width
        let width = min(textWidth + 28, frame.width - 16)
        let origin = NSPoint(x: frame.midX - width / 2, y: frame.minY + 6)
        panel.setFrame(NSRect(origin: origin,
                              size: NSSize(width: width, height: barHeight)),
                       display: true)
        field.frame = NSRect(x: 14, y: (barHeight - 20) / 2,
                             width: width - 28, height: 20)
        isShown = true
        panel.orderFrontRegardless()
    }

    private func ensurePanel() -> (NSPanel, NSTextField) {
        if let panel, let field { return (panel, field) }
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true   // pure display, clicks fall through
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor =
            NSColor(calibratedWhite: 0.75, alpha: 0.95).cgColor
        content.layer?.cornerRadius = 6

        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byClipping
        content.addSubview(field)

        panel.contentView = content
        self.panel = panel
        self.field = field
        return (panel, field)
    }
}
