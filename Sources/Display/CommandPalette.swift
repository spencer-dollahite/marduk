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
    /// top-down row index; rows start below the logo + prompt header).
    private final class PaletteView: NSView {
        var lineHeight: CGFloat = 26
        var padding: CGFloat = 14
        var headerHeight: CGFloat = 26   // logo block + prompt line, in points
        var rowCount = 0
        /// Index of the first VISIBLE candidate. The list scrolls once it
        /// exceeds maxRows, and `onRowClick` is consumed as an index into
        /// the FULL candidate list — so a click must be offset by this or
        /// it selects a different command than the one under the cursor.
        var firstRow = 0
        var onRowClick: ((Int) -> Void)?

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let fromTop = bounds.height - padding - point.y
            let row = Int(floor((fromTop - headerHeight) / lineHeight))
            if row >= 0 && row < rowCount { onRowClick?(firstRow + row) }
        }
    }

    /// Click on a candidate row — daemon treats it like Tab on that row.
    var onRowClick: ((Int) -> Void)?

    enum PositionMode: String { case center, pointer }
    /// "pointer" opens at the cursor — zoom always keeps the real cursor in
    /// view, so the palette lands inside a zoomed viewport by definition
    /// (zoom pans only on hardware pointer deltas; nothing synthetic
    /// reaches it — user-verified). Set from the main queue.
    var positionMode: PositionMode = .center

    /// Real, focused text view for the prompt so macOS treats the palette
    /// like any text box: a genuine blinking insertion caret plus the AX
    /// focus/caret notifications that zoom's follow-focus modes track
    /// natively. All input still comes from the event tap — real keystrokes
    /// that reach this view are swallowed so nothing double-types.
    private final class PromptTextView: NSTextView {
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {}       // the tap owns input
        override func insertText(_ string: Any, replacementRange: NSRange) {}
        override func doCommand(by selector: Selector) {}   // no beeps on arrows
    }

    private var panel: NSPanel?
    private var paletteView: PaletteView?
    private var textField: NSTextField?
    private var promptView: PromptTextView?
    private var previousApp: NSRunningApplication?
    private var sessionAnchor: NSPoint?   // pointer mode: fixed per session
    private var isShown = false

    private let width: CGFloat = 640
    private let lineHeight: CGFloat = 26
    private let padding: CGFloat = 14
    // Wordmark at ~1/3 scale of the rows; fixed line heights keep the
    // computed geometry (and click mapping) exact.
    private let logoFontSize: CGFloat = 7
    private let logoLineHeight: CGFloat = 8.5
    private let logoGap: CGFloat = 10   // air between the wordmark and the prompt
    // Tall enough for every current list (11 commands / 11 settings) — and
    // overflow is never silent: a "… and N more" row appears, so what you
    // see always matches what the options speech says.
    private let maxRows = 16

    /// The full MARDUK wordmark, same block style as the repo logo's M.
    private static let logoLines = [
        "███╗   ███╗ █████╗ ██████╗ ██████╗ ██╗   ██╗██╗  ██╗",
        "████╗ ████║██╔══██╗██╔══██╗██╔══██╗██║   ██║██║ ██╔╝",
        "██╔████╔██║███████║██████╔╝██║  ██║██║   ██║█████╔╝ ",
        "██║╚██╔╝██║██╔══██║██╔══██╗██║  ██║██║   ██║██╔═██╗ ",
        "██║ ╚═╝ ██║██║  ██║██║  ██║██████╔╝╚██████╔╝██║  ██╗",
        "╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝  ╚═════╝ ╚═╝  ╚═╝",
    ]

    /// Which slice of the candidate list is on screen, given the selection.
    ///
    /// Pure so the renderer and the click-row mapping can be proven to agree
    /// — they must, or a click lands on a different command than the one the
    /// user sees highlighted. Keeps the selection inside the window by
    /// scrolling the minimum distance, like a terminal pager.
    static func visibleWindow(selected: Int, count: Int, maxRows: Int) -> Range<Int> {
        guard count > 0, maxRows > 0 else { return 0..<0 }
        guard count > maxRows else { return 0..<count }
        let selected = max(0, min(selected, count - 1))
        // Scroll only far enough to bring the selection back into view.
        var first = min(selected, count - maxRows)
        if selected >= first + maxRows { first = selected - maxRows + 1 }
        first = max(0, min(first, count - maxRows))
        return first..<(first + maxRows)
    }

    func update(buffer: String, candidates: [CommandCompleter.Candidate], selected: Int) {
        DispatchQueue.main.async { [self] in
            let visible = min(candidates.count, maxRows)
            let overflow = candidates.count - visible
            let text = composed(buffer: buffer, candidates: candidates,
                                selected: selected, overflow: overflow)
            let logoHeight = CGFloat(Self.logoLines.count) * logoLineHeight
            let headerHeight = logoHeight + logoGap + lineHeight   // logo + gap + prompt
            let rowLines = visible + (overflow > 0 ? 1 : 0)
            let contentHeight = headerHeight + CGFloat(rowLines) * lineHeight
            layoutAndShow(text: text, contentHeight: contentHeight,
                          headerHeight: headerHeight, rowCount: visible,
                          firstRow: Self.visibleWindow(selected: selected,
                                                       count: candidates.count,
                                                       maxRows: maxRows).lowerBound)
            // Real prompt text + caret-at-end. setSelectedRange on a focused
            // view fires the AX caret notification zoom follows.
            if let prompt = promptView {
                let line = ": \(buffer)"
                prompt.string = line
                prompt.setSelectedRange(NSRange(location: (line as NSString).length,
                                                length: 0))
                // Belt-and-suspenders for zoom's focus-following: post the
                // caret-moved AND value-changed notifications explicitly —
                // programmatic .string updates may emit neither, and the
                // user's Spotlight observation (zoom pans only AFTER a
                // letter is typed) fingers value-changed as zoom's trigger.
                NSAccessibility.post(element: prompt, notification: .selectedTextChanged)
                NSAccessibility.post(element: prompt, notification: .valueChanged)
            }
        }
    }

    func hide() {
        DispatchQueue.main.async { [self] in
            guard isShown else { return }
            isShown = false
            sessionAnchor = nil
            panel?.orderOut(nil)
            // Hand keyboard focus straight back to where the user was
            _ = previousApp?.activate()
            previousApp = nil
        }
    }

    // MARK: - Rendering (main thread only)

    private func composed(buffer: String, candidates: [CommandCompleter.Candidate],
                          selected: Int, overflow: Int) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        let logoFont = NSFont.monospacedSystemFont(ofSize: logoFontSize, weight: .regular)
        // Fixed line heights so the drawn text matches the computed
        // geometry (and the click-row mapping) exactly
        let logoStyle = NSMutableParagraphStyle()
        logoStyle.minimumLineHeight = logoLineHeight
        logoStyle.maximumLineHeight = logoLineHeight
        let rowStyle = NSMutableParagraphStyle()
        rowStyle.minimumLineHeight = lineHeight
        rowStyle.maximumLineHeight = lineHeight
        let promptStyle = rowStyle.mutableCopy() as! NSMutableParagraphStyle
        promptStyle.paragraphSpacingBefore = logoGap

        let result = NSMutableAttributedString()
        for line in Self.logoLines {
            result.append(NSAttributedString(
                string: line + "\n",
                attributes: [.font: logoFont, .foregroundColor: NSColor.white,
                             .paragraphStyle: logoStyle]))
        }
        // Spacer where the prompt line sits — the real PromptTextView (with
        // its native caret) is overlaid on this line
        result.append(NSAttributedString(
            string: "\n",
            attributes: [.font: font, .paragraphStyle: promptStyle]))

        // SCROLL the visible slice to follow the selection. Previously this
        // rendered a fixed `prefix(maxRows)` while the daemon wrapped the
        // selection modulo the FULL candidate count, so arrowing past row 15
        // — routine in the voice picker — highlighted nothing on screen
        // while the selection kept moving invisibly behind "… and N more".
        let window = Self.visibleWindow(selected: selected, count: candidates.count,
                                        maxRows: maxRows)
        for (offset, candidate) in candidates[window].enumerated() {
            let index = window.lowerBound + offset
            var attributes: [NSAttributedString.Key: Any] = [.font: font,
                                                             .paragraphStyle: rowStyle]
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
                attributes: [.font: font, .paragraphStyle: rowStyle,
                             .foregroundColor: NSColor(white: 0.55, alpha: 1.0)]))
        }
        return result
    }

    private func layoutAndShow(text: NSAttributedString, contentHeight: CGFloat,
                               headerHeight: CGFloat, rowCount: Int,
                               firstRow: Int) {
        let (panel, field) = ensurePanel()
        field.attributedStringValue = text
        let height = padding * 2 + contentHeight

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        let origin: NSPoint
        switch positionMode {
        case .center:
            // Fully centered on the pointer's screen (the default look)
            origin = NSPoint(x: frame.midX - width / 2, y: frame.midY - height / 2)
        case .pointer:
            // Anchored at the cursor for the session — inside any zoomed
            // viewport, since zoom keeps the real cursor visible
            if sessionAnchor == nil {
                sessionAnchor = NSPoint(
                    x: max(frame.minX + 8, min(mouse.x - width / 2, frame.maxX - width - 8)),
                    y: mouse.y - 24)
            }
            let anchor = sessionAnchor ?? .zero
            origin = NSPoint(x: anchor.x,
                             y: max(frame.minY + 8, anchor.y - height))
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)),
                       display: true)
        field.frame = NSRect(x: padding, y: padding,
                             width: width - padding * 2, height: height - padding * 2)
        paletteView?.lineHeight = lineHeight
        paletteView?.padding = padding
        paletteView?.headerHeight = headerHeight
        paletteView?.rowCount = rowCount   // excludes any "… and N more" row
        paletteView?.firstRow = firstRow   // the list scrolls; clicks offset by it
        // Overlay the real prompt view on its spacer line
        promptView?.frame = NSRect(x: padding, y: height - padding - headerHeight,
                                   width: width - padding * 2, height: lineHeight)

        if !isShown {
            isShown = true
            // Remember who had focus, then take it — the tap feeds us input
            // regardless; key status just parks the app's caret and catches
            // any events the tap passes through.
            previousApp = NSWorkspace.shared.frontmostApplication
            NSApp.activate()
            // Cooperative activation (the only non-deprecated call) can be
            // REFUSED — fullscreen zoom does this. Verify it landed; if not,
            // force it through the legacy path via the runtime (the direct
            // call is deprecated and the build must stay warning-free).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.isShown, !NSApp.isActive else { return }
                fputs("[palette] cooperative activation refused — forcing\n", stderr)
                let selector = NSSelectorFromString("activateIgnoringOtherApps:")
                if NSApp.responds(to: selector) {
                    NSApp.perform(selector, with: true)
                }
                self.panel?.makeKeyAndOrderFront(nil)
                if let prompt = self.promptView { self.panel?.makeFirstResponder(prompt) }
            }
            // NOTE: no pointer warping/gliding — macOS zoom pans only on
            // hardware pointer deltas (user-verified: warps, synthetic
            // moves, and interpolated glides all failed to pan it). The
            // zoom answers are positionMode == .pointer, and the REAL
            // focused prompt caret below, which zoom's follow-focus modes
            // track natively.
        }
        panel.makeKeyAndOrderFront(nil)
        if let prompt = promptView {
            panel.makeFirstResponder(prompt)
            NSAccessibility.post(element: prompt, notification: .focusedUIElementChanged)
        }
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

        let prompt = PromptTextView()
        prompt.isEditable = true          // a real, blinking insertion caret
        prompt.isRichText = false
        prompt.drawsBackground = false
        prompt.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        prompt.textColor = .white
        prompt.insertionPointColor = .white
        prompt.setAccessibilityLabel("Marduk command")
        content.addSubview(prompt)

        panel.contentView = content
        self.panel = panel
        self.paletteView = content
        self.textField = field
        self.promptView = prompt
        return (panel, field)
    }
}
