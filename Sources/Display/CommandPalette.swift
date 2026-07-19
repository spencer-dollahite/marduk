import AppKit

/// Dmenu-style command panel rendering the ":" buffer and its completion
/// candidates. INPUT still flows through the event tap — the panel's job is
/// visual — but while open it takes keyboard focus (Spotlight-style) so the
/// app underneath stops blinking its caret and receives nothing; focus is
/// handed straight back to that app on dismiss.
/// Methods only dispatch to the main queue and never block the tap callback.
final class CommandPalette {

    /// Borderless panels refuse key status by default.
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    /// Content view that maps clicks to candidate rows (bottom-up coords →
    /// top-down row index; row 0 sits one line below the prompt).
    private final class PaletteView: NSView {
        var lineHeight: CGFloat = 26
        var padding: CGFloat = 14
        var rowCount = 0
        var onRowClick: ((Int) -> Void)?

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let fromTop = bounds.height - padding - point.y
            let row = Int(floor(fromTop / lineHeight)) - 1
            if row >= 0 && row < rowCount { onRowClick?(row) }
        }
    }

    /// Click on a candidate row — daemon treats it like Tab on that row.
    var onRowClick: ((Int) -> Void)?

    private var panel: NSPanel?
    private var paletteView: PaletteView?
    private var textField: NSTextField?
    private var previousApp: NSRunningApplication?
    private var isShown = false

    private let width: CGFloat = 640
    private let lineHeight: CGFloat = 26
    private let padding: CGFloat = 14
    // Tall enough for every current list (11 commands / 11 settings) — and
    // overflow is never silent: a "… and N more" row appears, so what you
    // see always matches what the options speech says.
    private let maxRows = 16

    func update(buffer: String, candidates: [CommandCompleter.Candidate], selected: Int) {
        DispatchQueue.main.async { [self] in
            let visible = min(candidates.count, maxRows)
            let overflow = candidates.count - visible
            let text = composed(buffer: buffer, candidates: candidates,
                                selected: selected, overflow: overflow)
            let lines = 1 + visible + (overflow > 0 ? 1 : 0)
            layoutAndShow(text: text, lines: lines, rowCount: visible)
        }
    }

    func hide() {
        DispatchQueue.main.async { [self] in
            guard isShown else { return }
            isShown = false
            panel?.orderOut(nil)
            // Hand keyboard focus straight back to where the user was
            previousApp?.activate()
            previousApp = nil
        }
    }

    // MARK: - Rendering (main thread only)

    private func composed(buffer: String, candidates: [CommandCompleter.Candidate],
                          selected: Int, overflow: Int) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        let result = NSMutableAttributedString()

        result.append(NSAttributedString(
            string: ": \(buffer)\u{258F}\n",
            attributes: [.font: font, .foregroundColor: NSColor.white]))

        for (index, candidate) in candidates.prefix(maxRows).enumerated() {
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if candidate.completion == nil {
                // Informational row (range hints) — dimmed, never highlighted
                attributes[.foregroundColor] = NSColor(white: 0.55, alpha: 1.0)
            } else if index == selected {
                attributes[.foregroundColor] = NSColor.black
                attributes[.backgroundColor] = NSColor(calibratedRed: 0.45, green: 0.8,
                                                       blue: 1.0, alpha: 1.0)
            } else {
                attributes[.foregroundColor] = NSColor(white: 0.82, alpha: 1.0)
            }
            result.append(NSAttributedString(string: "  \(candidate.display)  \n",
                                             attributes: attributes))
        }
        if overflow > 0 {
            result.append(NSAttributedString(
                string: "  … and \(overflow) more\n",
                attributes: [.font: font,
                             .foregroundColor: NSColor(white: 0.55, alpha: 1.0)]))
        }
        return result
    }

    private func layoutAndShow(text: NSAttributedString, lines: Int, rowCount: Int) {
        let (panel, field) = ensurePanel()
        field.attributedStringValue = text
        let height = padding * 2 + CGFloat(lines) * lineHeight

        // Fully centered on the screen the pointer is on. (Centering was the
        // user's call over pointer-following; under fullscreen zoom the
        // center may sit outside the magnified viewport — zoom out to see it.)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrame(NSRect(x: frame.midX - width / 2,
                              y: frame.midY - height / 2,
                              width: width, height: height), display: true)
        field.frame = NSRect(x: padding, y: padding,
                             width: width - padding * 2, height: height - padding * 2)
        paletteView?.lineHeight = lineHeight
        paletteView?.padding = padding
        paletteView?.rowCount = rowCount   // excludes any "… and N more" row

        if !isShown {
            isShown = true
            // Remember who had focus, then take it — the tap feeds us input
            // regardless; key status just parks the app's caret and catches
            // any events the tap passes through.
            previousApp = NSWorkspace.shared.frontmostApplication
            NSApp.activate()
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func ensurePanel() -> (NSPanel, NSTextField) {
        if let panel, let textField { return (panel, textField) }

        let panel = KeyablePanel(contentRect: .zero,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        // .floating, not .screenSaver — the aggressive level fought the zoom
        // compositor (broken zoom state while the palette was open)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = false   // rows are clickable
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = PaletteView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.07, alpha: 0.95).cgColor
        content.layer?.cornerRadius = 10
        content.onRowClick = { [weak self] row in self?.onRowClick?(row) }

        let field = NSTextField(labelWithString: "")
        field.maximumNumberOfLines = 0
        field.cell?.usesSingleLineMode = false
        field.lineBreakMode = .byClipping
        content.addSubview(field)

        panel.contentView = content
        self.panel = panel
        self.paletteView = content
        self.textField = field
        return (panel, field)
    }
}
