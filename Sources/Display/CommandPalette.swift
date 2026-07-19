import AppKit

/// Dmenu-style command panel: a display-only, non-activating floating window
/// that renders the ":" buffer and its completion candidates. All input stays
/// in the event tap — this window never takes focus and ignores the mouse, so
/// the frontmost app keeps its keyboard focus the whole time.
/// Methods only dispatch to the main queue and never block the tap callback.
final class CommandPalette {
    private var panel: NSPanel?
    private var textField: NSTextField?

    private let width: CGFloat = 640
    private let lineHeight: CGFloat = 26
    private let padding: CGFloat = 14
    private let maxRows = 8

    func update(buffer: String, candidates: [CommandCompleter.Candidate], selected: Int) {
        DispatchQueue.main.async { [self] in
            let text = composed(buffer: buffer, candidates: candidates, selected: selected)
            let lines = 1 + min(candidates.count, maxRows)
            layoutAndShow(text: text, lines: lines)
        }
    }

    func hide() {
        DispatchQueue.main.async { [self] in
            panel?.orderOut(nil)
        }
    }

    // MARK: - Rendering (main thread only)

    private func composed(buffer: String, candidates: [CommandCompleter.Candidate],
                          selected: Int) -> NSAttributedString {
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
        return result
    }

    private func layoutAndShow(text: NSAttributedString, lines: Int) {
        let (panel, field) = ensurePanel()
        field.attributedStringValue = text

        guard let screen = NSScreen.main else { return }
        let height = padding * 2 + CGFloat(lines) * lineHeight
        let frame = screen.visibleFrame
        let x = frame.midX - width / 2
        // Spotlight-ish: hangs in the upper third of the screen
        let y = frame.maxY - frame.height * 0.18 - height
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        field.frame = NSRect(x: padding, y: padding,
                             width: width - padding * 2, height: height - padding * 2)
        panel.orderFrontRegardless()
    }

    private func ensurePanel() -> (NSPanel, NSTextField) {
        if let panel, let textField { return (panel, textField) }

        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.07, alpha: 0.95).cgColor
        content.layer?.cornerRadius = 10

        let field = NSTextField(labelWithString: "")
        field.maximumNumberOfLines = 0
        field.cell?.usesSingleLineMode = false
        field.lineBreakMode = .byClipping
        content.addSubview(field)

        panel.contentView = content
        self.panel = panel
        self.textField = field
        return (panel, field)
    }
}
