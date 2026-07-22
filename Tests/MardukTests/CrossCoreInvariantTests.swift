import XCTest
@testable import marduk

/// Places where two cores MUST agree and nothing checked it.
///
/// Each is a table on one side and a consumer on the other, wired only by
/// convention. Every failure mode here is silent: the value is offered, it
/// parses, and then something downstream quietly refuses it or can't find
/// it. They all pass today — the point is that they keep passing.
final class CrossCoreInvariantTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MardukTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        return try String(contentsOf: root.appendingPathComponent(relativePath),
                          encoding: .utf8)
    }

    // MARK: - The settings table vs the thing that executes it

    /// `ColonCommand.settings` is what the palette offers and what `parse`
    /// accepts; `applyConfig`'s switch is what actually does the work. A row
    /// added without a case is offered, autocompletes, parses cleanly — and
    /// then tells the user the setting doesn't exist.
    ///
    /// `applyConfig` needs a live daemon, so this reads its source. That is
    /// the codebase's established escape hatch for logic behind a system
    /// boundary (see HoverDwellTests and ReleaseScriptTests).
    func testEverySettingHasAnApplyConfigCase() throws {
        let daemon = try source("Sources/App/Daemon.swift")
        guard let start = daemon.range(of: "private func applyConfig") else {
            return XCTFail("applyConfig moved — this guard needs re-anchoring")
        }
        let body = String(daemon[start.lowerBound...])
        for setting in ColonCommand.settings {
            XCTAssertTrue(
                body.contains("case \"\(setting.key)\":"),
                "'\(setting.key)' is in the settings table but applyConfig has "
                + "no case for it — the palette offers it, it parses, and then "
                + "the user is told it doesn't exist")
        }
    }

    /// …and the reverse: a case with no table row is unreachable, because
    /// `parse` only expands against the table.
    func testEveryApplyConfigCaseHasASettingsRow() throws {
        let daemon = try source("Sources/App/Daemon.swift")
        guard let start = daemon.range(of: "private func applyConfig"),
              let end = daemon.range(of: "\n    /// Applies and persists",
                                     range: start.upperBound..<daemon.endIndex)
                ?? daemon.range(of: "\n    private func ",
                                range: start.upperBound..<daemon.endIndex) else {
            return XCTFail("could not bound applyConfig")
        }
        let body = String(daemon[start.upperBound..<end.lowerBound])
        let keys = Set(ColonCommand.settings.map(\.key))
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("case \""), trimmed.hasSuffix("\":") else { continue }
            let key = String(trimmed.dropFirst(6).dropLast(2))
            XCTAssertTrue(keys.contains(key),
                          "applyConfig handles '\(key)' but no settings row "
                          + "offers it — it is unreachable")
        }
    }

    // MARK: - Choice lists vs the enums that consume them

    /// Three raw-value string pairs wired only by convention. Rename a case
    /// and the palette still offers the old spelling, which then fails to
    /// initialize its enum and silently falls back to a default.
    func testChoiceValuesMatchTheirConsumingEnums() {
        func choices(_ key: String) -> [String] {
            guard case .choice(let options)? = ColonCommand.kind(for: key) else {
                XCTFail("'\(key)' is no longer a choice setting")
                return []
            }
            return options
        }

        XCTAssertEqual(Set(choices("level")),
                       Set(["none", "some", "most", "all"]))
        for value in choices("level") {
            XCTAssertNotNil(SpeechPreprocessor.Verbosity(rawValue: value),
                            "verbalizer level '\(value)' has no Verbosity case")
        }
        for value in choices("dialogfocus") {
            XCTAssertNotNil(DialogFocus.Setting(rawValue: value),
                            "dialogfocus '\(value)' has no Setting case")
        }
        for value in choices("dialogs") {
            XCTAssertNotNil(DialogSentinel.Level(rawValue: value),
                            "dialogs '\(value)' has no Level case")
        }
        for value in choices("pdfdark") {
            XCTAssertNotNil(DisplayInverter.PDFDarkStyle(rawValue: value),
                            "pdfdark '\(value)' has no PDFDarkStyle case")
        }
        for value in choices("position") {
            XCTAssertNotNil(CommandPalette.PositionMode(rawValue: value),
                            "palette position '\(value)' has no PositionMode case")
        }
    }

    /// The other direction: an enum case the settings table never offers is
    /// a feature no user can reach.
    func testEveryConsumingEnumCaseIsOfferable() {
        func choices(_ key: String) -> Set<String> {
            guard case .choice(let options)? = ColonCommand.kind(for: key) else { return [] }
            return Set(options)
        }
        for verbosity in ["none", "some", "most", "all"] {
            XCTAssertTrue(choices("level").contains(verbosity),
                          "Verbosity.\(verbosity) is unreachable from :config")
        }
        for setting in ["ask", "always", "off"] {
            XCTAssertTrue(choices("dialogfocus").contains(setting),
                          "DialogFocus.Setting.\(setting) is unreachable")
        }
        for level in ["all", "system", "off"] {
            XCTAssertTrue(choices("dialogs").contains(level),
                          "DialogSentinel.Level.\(level) is unreachable")
        }
    }

    // MARK: - The command-letter table vs the NORMAL dispatch

    /// `BurstPolicy.commandLetterKeys` decides which letters the typing
    /// rescue treats as deliberate commands; the NORMAL switch is what
    /// actually runs them. Add a letter to the dispatch without adding it
    /// here and, with typing rescue on (the default), the key becomes
    /// un-invokable — it rescues as typing every time.
    func testEveryCommandLetterIsDispatchedInNormalMode() throws {
        let monitor = try source("Sources/Input/KeyboardMonitor.swift")
        // The NORMAL dispatch is a `switch keycode` with `case <code>:` arms
        for key in BurstPolicy.commandLetterKeys {
            XCTAssertTrue(
                monitor.contains("case \(key)"),
                "keycode \(key) is a command letter but NORMAL mode never "
                + "dispatches it — typing rescue would swallow it forever")
        }
    }

    /// `oneShotNormalKeys` is derived from the command letters so autorepeat
    /// suppression can't fall behind. Pin the derivation.
    func testAutorepeatSuppressionCoversEveryCommandLetter() throws {
        let monitor = try source("Sources/Input/KeyboardMonitor.swift")
        XCTAssertTrue(
            monitor.contains("commandLetterKeys = BurstPolicy.commandLetterKeys"),
            "the monitor's command letters must stay aliased to BurstPolicy's, "
            + "or the rescue and the dispatch can disagree about what a "
            + "command letter is")
        XCTAssertTrue(
            monitor.contains("commandLetterKeys.union"),
            "oneShotNormalKeys must stay DERIVED from the command letters, "
            + "or a new command letter gets no autorepeat suppression")
    }

    // MARK: - Line offsets: two functions that claim to be inverses

    /// `ReadNavigator.lineStartOffsets` and `KeyboardMonitor.lineIndex` are
    /// documented as inverses and tested only apart. Their join is what
    /// drives scroll-follow and the heading harvest, so a disagreement
    /// scrolls the page to the wrong paragraph.
    func testLineOffsetsAndLineIndexAreInverses() {
        let texts = [
            "one\ntwo\nthree",
            "\nleading blank\n\ndouble\n",
            "no newlines at all",
            "trailing\n",
            "unicode ✅ line\nsecond ✅\nthird",
        ]
        for text in texts {
            let starts = ReadNavigator.lineStartOffsets(in: text)
            for (index, offset) in starts.enumerated() {
                XCTAssertEqual(
                    KeyboardMonitor.lineIndex(of: offset, in: text), index,
                    "line \(index) at offset \(offset) round-tripped wrong in "
                    + "\(text.debugDescription)")
            }
        }
    }

    // MARK: - Page numbering: 1-based edges vs 0-based indices

    /// `documentEdge` speaks in 1-based page numbers; `PagedText` indexes
    /// from 0. An off-by-one here is `gg` landing on page 2, or `G`
    /// trapping past the end.
    func testDocumentEdgesLandOnRealPages() {
        let pages = (0..<40).map { "page \($0) body text" }
        let paged = PagedText(pages: pages)

        guard case .page(let top) = ModePolicy.documentEdge(
            forward: false, isPaged: true, pageCount: paged.pageCount),
              case .page(let bottom) = ModePolicy.documentEdge(
                forward: true, isPaged: true, pageCount: paged.pageCount) else {
            return XCTFail("paged edges must resolve to pages")
        }
        XCTAssertEqual(top, 1)
        XCTAssertEqual(bottom, paged.pageCount)
        // Converted to indices the way the engine does (number - 1), both
        // must be inside the document.
        XCTAssertTrue(paged.pageStarts.indices.contains(top - 1))
        XCTAssertTrue(paged.pageStarts.indices.contains(bottom - 1))
        XCTAssertEqual(paged.pageIndex(at: paged.pageStarts[top - 1]), 0)
        XCTAssertEqual(paged.pageIndex(at: paged.pageStarts[bottom - 1]),
                       paged.pageCount - 1)
    }

    // MARK: - Hints promise keys; the keys must exist

    /// `Onboarding.catalog` tells users which keys to press. Nothing checked
    /// those keys are real — precisely the "silent by construction" failure
    /// DriftGuardTests exists for, but about behavior rather than spelling.
    func testHintsOnlyPromiseKeysThatExist() throws {
        let monitor = try source("Sources/Input/KeyboardMonitor.swift")
        // (spoken claim, the keycode that must be dispatched)
        let claims: [(needle: String, keycode: Int64, what: String)] = [
            ("j and k", 38, "j — line forward"),
            ("j and k", 40, "k — line back"),
            ("Space pauses", 49, "Space — pause/resume"),
            ("Control F and Control B", 3, "Ctrl+F — page forward"),
            ("Control F and Control B", 11, "Ctrl+B — page back"),
            ("Control G", 5, "Ctrl+G — position"),
            ("z spells", 6, "z — spell"),
        ]
        let spoken = Onboarding.catalog.map(\.text).joined(separator: " ")
        for claim in claims where spoken.contains(claim.needle) {
            XCTAssertTrue(
                monitor.contains("keycode == \(claim.keycode)")
                    || monitor.contains("case \(claim.keycode)"),
                "a hint promises \(claim.what) but the dispatch has no "
                + "handler for keycode \(claim.keycode)")
        }
    }

    /// Every hint must name at least one key or setting a user can act on —
    /// a tip with nothing actionable in it is noise in a limited budget.
    func testEveryHintIsActionable() {
        for hint in Onboarding.catalog {
            let text = hint.text.lowercased()
            let actionable = ["control", "escape", "space", "colon config",
                              "uppercase", " j ", " k ", " z ", " r "]
            XCTAssertTrue(actionable.contains { text.contains($0) },
                          "hint '\(hint.id)' names nothing the user can press")
        }
    }
}
