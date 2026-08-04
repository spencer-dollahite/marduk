import AppKit

/// The STOCKS mode TUI: a terminal-styled panel — title bar, aligned
/// ticker rows, and a newsboat-style key-help status bar along the
/// bottom. DISPLAY ONLY: unlike the command palette it never takes key
/// focus and never activates Marduk — the event tap owns every key; the
/// panel just shows what the voice is saying. Rows are clickable
/// (click = move the spoken cursor there). Methods dispatch to main and
/// never block the tap callback.
final class StocksPanel {

    struct Row: Equatable {
        var symbol: String
        var price: String    // "309.86" or "…" while fetching
        var change: String   // "+1.2%" / "-0.8%" / ""
        var alerts: String   // "↓180 ↑220" — armed levels, visual only
        var current: Bool
    }

    /// Click on a ticker row — the daemon moves the spoken cursor there.
    var onRowClick: ((Int) -> Void)?
    /// Same semantics as the palette's mode: "pointer" keeps the panel
    /// inside a zoomed viewport. Set from the main queue.
    var positionMode: CommandPalette.PositionMode = .pointer

    private final class RowsView: NSView {
        var lineHeight: CGFloat = 24
        var padding: CGFloat = 12
        var headerHeight: CGFloat = 24
        var rowCount = 0
        var firstRow = 0
        var onRowClick: ((Int) -> Void)?

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let fromTop = bounds.height - padding - point.y
            let row = Int(floor((fromTop - headerHeight) / lineHeight))
            if row >= 0 && row < rowCount { onRowClick?(firstRow + row) }
        }
    }

    private var panel: NSPanel?
    private var rowsView: RowsView?
    private var textField: NSTextField?
    private var sessionAnchor: NSPoint?
    private var isShown = false

    private let width: CGFloat = 560
    private let lineHeight: CGFloat = 24
    private let padding: CGFloat = 12
    private let maxRows = 20

    static let keyBar =
        " j/k move   ⏎/r detail   a add   dd remove   b buy   s sell   esc quit "

    /// Fixed-width TUI columns: symbol, right-aligned price and change,
    /// then alerts. Pure so the layout is testable.
    static func columns(_ row: Row) -> String {
        let symbol = row.symbol.padding(toLength: 9, withPad: " ",
                                        startingAt: 0)
        let price = String(repeating: " ",
                           count: max(0, 10 - row.price.count)) + row.price
        let change = String(repeating: " ",
                            count: max(0, 8 - row.change.count)) + row.change
        let alerts = row.alerts.isEmpty ? "" : "   \(row.alerts)"
        return " \(symbol)\(price)\(change)\(alerts)"
    }

    func update(rows: [Row]) {
        DispatchQueue.main.async { [self] in render(rows) }
    }

    func hide() {
        DispatchQueue.main.async { [self] in
            guard isShown else { return }
            isShown = false
            sessionAnchor = nil
            panel?.orderOut(nil)
        }
    }

    // MARK: - Rendering (main thread only)

    private func render(_ rows: [Row]) {
        let (panel, field) = ensurePanel()
        let selected = rows.firstIndex(where: \.current) ?? 0
        let window = CommandPalette.visibleWindow(selected: selected,
                                                 count: rows.count,
                                                 maxRows: maxRows)
        let overflow = rows.count - window.count

        let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        let barColor = NSColor(calibratedWhite: 0.75, alpha: 1.0)

        let text = NSMutableAttributedString()
        let title = " MARDUK STOCKS ── \(rows.count) "
            + (rows.count == 1 ? "ticker " : "tickers ")
        text.append(NSAttributedString(
            string: pad(title) + "\n",
            attributes: [.font: font, .paragraphStyle: style,
                         .foregroundColor: NSColor.black,
                         .backgroundColor: barColor]))

        if rows.isEmpty {
            text.append(NSAttributedString(
                string: "  watchlist empty — press a to add a ticker\n",
                attributes: [.font: font, .paragraphStyle: style,
                             .foregroundColor: NSColor(white: 0.55, alpha: 1)]))
        }
        for row in rows[window] {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .paragraphStyle: style,
            ]
            if row.current {
                attributes[.foregroundColor] = NSColor.black
                attributes[.backgroundColor] = NSColor(calibratedRed: 0.45,
                                                       green: 0.8, blue: 1.0,
                                                       alpha: 1.0)
                text.append(NSAttributedString(string: pad(Self.columns(row)) + "\n",
                                               attributes: attributes))
            } else {
                attributes[.foregroundColor] = NSColor(white: 0.85, alpha: 1.0)
                text.append(NSAttributedString(string: Self.columns(row) + "\n",
                                               attributes: attributes))
            }
        }
        if overflow > 0 {
            text.append(NSAttributedString(
                string: "  … and \(overflow) more\n",
                attributes: [.font: font, .paragraphStyle: style,
                             .foregroundColor: NSColor(white: 0.55, alpha: 1)]))
        }
        text.append(NSAttributedString(
            string: pad(Self.keyBar),
            attributes: [.font: font, .paragraphStyle: style,
                         .foregroundColor: NSColor.black,
                         .backgroundColor: barColor]))
        field.attributedStringValue = text

        let bodyRows = max(rows.isEmpty ? 1 : window.count, 1)
            + (overflow > 0 ? 1 : 0)
        let height = padding * 2 + CGFloat(bodyRows + 2) * lineHeight
        place(panel: panel, height: height)
        field.frame = NSRect(x: padding, y: padding,
                             width: width - padding * 2,
                             height: height - padding * 2)
        rowsView?.lineHeight = lineHeight
        rowsView?.padding = padding
        rowsView?.headerHeight = lineHeight
        rowsView?.rowCount = rows.isEmpty ? 0 : window.count
        rowsView?.firstRow = window.lowerBound
        if !isShown { isShown = true }
        panel.orderFrontRegardless()   // visible, never key, never activating
    }

    /// Pad a bar line so its background stripe spans the panel width.
    private func pad(_ line: String) -> String {
        let columns = Int((width - padding * 2) / 9.0)  // ~15pt mono advance
        guard line.count < columns else { return line }
        return line + String(repeating: " ", count: columns - line.count)
    }

    private func place(panel: NSPanel, height: CGFloat) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let origin: NSPoint
        switch positionMode {
        case .center:
            origin = NSPoint(x: frame.midX - width / 2,
                             y: frame.midY - height / 2)
        case .pointer:
            if sessionAnchor == nil {
                sessionAnchor = NSPoint(
                    x: max(frame.minX + 8,
                           min(mouse.x - width / 2, frame.maxX - width - 8)),
                    y: mouse.y - 24)
            }
            let anchor = sessionAnchor ?? .zero
            origin = NSPoint(x: anchor.x,
                             y: max(frame.minY + 8, anchor.y - height))
        }
        panel.setFrame(NSRect(origin: origin,
                              size: NSSize(width: width, height: height)),
                       display: true)
    }

    private func ensurePanel() -> (NSPanel, NSTextField) {
        if let panel, let textField { return (panel, textField) }
        // Plain NSPanel — canBecomeKey stays false, and .nonactivatingPanel
        // means row clicks never pull focus off the user's app
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = RowsView()
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
        self.rowsView = content
        self.textField = field
        return (panel, field)
    }
}
