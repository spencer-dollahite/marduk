import XCTest
import CoreGraphics
@testable import marduk

/// What a daemon that runs for weeks must not do to the machine around it.
///
/// Field report, 2026-09-04: "the pointer seriously slows down after
/// several days" — and the health line showed Marduk's OWN process flat
/// across those days. So the suspects are the things this process leaves
/// behind in OTHER processes and in the event path, none of which any
/// in-process metric can see. Each guard here pins one of them:
///
/// - accessibility flags set on other apps are LEDGERED and restored;
/// - AX observer registrations are taken back from the observed app;
/// - the subsystems that install timers/observers are re-entrant-safe;
/// - Marduk's tap stays OUT of the pointer-motion path.
///
/// Source-level guards are the codebase's established escape hatch for
/// logic behind a system boundary (CrossCoreInvariantTests, SpeechHealthTests).
final class ResourceHygieneTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MardukTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        return try String(contentsOf: root.appendingPathComponent(relativePath),
                          encoding: .utf8)
    }

    private func sourceFiles() throws -> [(path: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(atPath: root.path)
        var files: [(String, String)] = []
        while let rel = enumerator?.nextObject() as? String {
            guard rel.hasSuffix(".swift") else { continue }
            let text = try String(contentsOf: root.appendingPathComponent(rel),
                                  encoding: .utf8)
            files.append((rel, text))
        }
        XCTAssertGreaterThan(files.count, 10, "the source walk found nothing")
        return files
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    // MARK: - AXNudgeLedger: the promise to give flags back

    func testNotedFlagsAreOwedAndDrainEmptiesTheLedger() {
        var ledger = AXNudgeLedger()
        ledger.note(42, [.enhanced, .manual])
        ledger.note(7, [.enhanced])
        XCTAssertEqual(ledger.count, 2)
        let owed = ledger.drain()
        XCTAssertEqual(owed.map { $0.pid }, [7, 42], "deterministic order")
        XCTAssertEqual(owed[0].flags, [.enhanced])
        XCTAssertEqual(owed[1].flags, [.enhanced, .manual])
        XCTAssertEqual(ledger.count, 0)
        XCTAssertTrue(ledger.drain().isEmpty, "a second drain owes nothing")
    }

    func testRepeatedNudgesUnionRatherThanDuplicate() {
        // Two reads into the same browser owe ONE restore of both flags,
        // not two rows — and the second read must not lose the first's flag
        var ledger = AXNudgeLedger()
        ledger.note(42, [.enhanced])
        ledger.note(42, [.manual])
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger.drain().first?.flags, [.enhanced, .manual])
    }

    func testAQuitProcessOwesNothing() {
        // PIDs are recycled: a restore aimed at a dead app's PID could land
        // on a stranger. Termination forgets the row.
        var ledger = AXNudgeLedger()
        ledger.note(42, [.enhanced])
        ledger.forget(42)
        XCTAssertEqual(ledger.count, 0)
        XCTAssertTrue(ledger.drain().isEmpty)
    }

    func testInvalidPIDsAndEmptyFlagsAreIgnored() {
        var ledger = AXNudgeLedger()
        ledger.note(0, [.enhanced])
        ledger.note(-1, [.enhanced])
        ledger.note(42, [])
        XCTAssertEqual(ledger.count, 0)
    }

    // MARK: - One door for the flags

    /// The two attribute names may be spelled (as strings) in exactly one
    /// file — the ledger's. A harvest rung that sets one directly would
    /// set a per-process flag nobody restores, which is the bug this whole
    /// round exists to end.
    func testOnlyTheLedgerNamesTheAccessibilityFlags() throws {
        for (path, text) in try sourceFiles() {
            let quoted = count("\"AXEnhancedUserInterface\"", in: text)
                + count("\"AXManualAccessibility\"", in: text)
            if path.hasSuffix("AXNudge.swift") {
                XCTAssertEqual(quoted, 2, "the ledger names each flag once")
            } else {
                XCTAssertEqual(quoted, 0,
                               "\(path) sets an accessibility flag outside AXNudge")
            }
        }
    }

    func testEveryReadEndAndTeardownRestoresTheFlags() throws {
        let monitor = try source("Sources/Input/KeyboardMonitor.swift")
        // readStateChanged: both the captured and the capture-less end
        guard let stateFn = monitor.range(of: "func readStateChanged(") else {
            return XCTFail("readStateChanged moved")
        }
        let body = String(monitor[stateFn.lowerBound...].prefix(2500))
        XCTAssertGreaterThanOrEqual(count("AXNudge.shared.restoreAll(", in: body), 2,
                                    "a read ending must restore the flags on both exits")
        // stop(): synchronous, because the process is about to exit
        XCTAssertTrue(monitor.contains("AXNudge.shared.restoreAllNow(reason: \"shutdown\")"))
        // disengage (Ctrl+Option+M off)
        XCTAssertTrue(monitor.contains("restoreAll(reason: \"disengaged\")"))
        // a walk that nudged and then found nothing
        XCTAssertTrue(monitor.contains("restoreAll(reason: \"no document\")"))
    }

    // MARK: - AX observers are taken back from the observed process

    /// Every `AXObserverAddNotification` needs its `AXObserverRemoveNotification`
    /// in the same file: the registration lives in the OBSERVED app, and
    /// dropping our run loop source only tells our side. The sentinel used
    /// to leave one per app switch in every app the user visited.
    func testObserverRegistrationsAreBalancedPerFile() throws {
        var sawAny = false
        for (path, text) in try sourceFiles() {
            let adds = count("AXObserverAddNotification(", in: text)
            guard adds > 0 else { continue }
            sawAny = true
            let removes = count("AXObserverRemoveNotification(", in: text)
            XCTAssertEqual(adds, removes,
                           "\(path) registers \(adds) AX notification(s) but removes \(removes)")
        }
        XCTAssertTrue(sawAny, "the sentinel's observer registration moved")
    }

    // MARK: - Re-entrant starts must not stack timers

    func testInverterAndSentinelStartsRetireBeforeInstalling() throws {
        for (path, retire) in [
            ("Sources/Input/DisplayInverter.swift", "retireObservers()"),
            ("Sources/Input/DialogSentinel.swift", "stop()"),
        ] {
            let text = try source(path)
            guard let start = text.range(of: "    func start() {") else {
                return XCTFail("\(path): start() moved")
            }
            let afterStart = text[start.upperBound...]
            guard let install = afterStart.range(of: ".addObserver(") else {
                return XCTFail("\(path): start() installs no observer?")
            }
            let preamble = afterStart[..<install.lowerBound]
            XCTAssertTrue(preamble.contains(retire),
                          "\(path): start() must \(retire) before installing a second observer/timer")
        }
    }

    // MARK: - Our tap and the pointer

    /// Marduk's tap listens to keys and the left click. The moment it
    /// listened to mouse motion, every pointer movement in the session
    /// would wait on our callback — the exact symptom under investigation.
    func testOurEventTapNeverListensToPointerMotion() throws {
        let monitor = try source("Sources/Input/KeyboardMonitor.swift")
        guard let maskStart = monitor.range(of: "let eventMask: CGEventMask ="),
              let maskEnd = monitor[maskStart.upperBound...].range(of: "let refcon") else {
            return XCTFail("the tap mask moved")
        }
        let mask = String(monitor[maskStart.lowerBound..<maskEnd.lowerBound])
        for forbidden in ["mouseMoved", "Dragged", "scrollWheel", "AllEvents", "~0"] {
            XCTAssertFalse(mask.contains(forbidden),
                           "the tap mask listens to \(forbidden) — that puts Marduk in the pointer's path")
        }
        XCTAssertTrue(mask.contains("keyDown") && mask.contains("leftMouseDown"))
    }

    func testPointerMaskCoversMotionAndNotKeys() {
        let pointer = TapReport.pointerMask
        XCTAssertNotEqual(pointer & (1 << CGEventType.mouseMoved.rawValue), 0)
        XCTAssertNotEqual(pointer & (1 << CGEventType.leftMouseDragged.rawValue), 0)
        XCTAssertEqual(pointer & (1 << CGEventType.keyDown.rawValue), 0)
        XCTAssertEqual(pointer & (1 << CGEventType.leftMouseDown.rawValue), 0,
                       "a click is not pointer motion — our own tap takes clicks")
        // A tap for everything (~0) is a pointer tap by definition
        XCTAssertNotEqual(~CGEventMask(0) & pointer, 0)
    }

    func testTapEntryClassifiesByMask() {
        let ours = TapReport.entry(
            owner: "marduk", isOurs: true,
            mask: (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue),
            enabled: true, avgUsec: 40, maxUsec: 900)
        XCTAssertTrue(ours.listensToKeys)
        XCTAssertFalse(ours.listensToPointer)
        let everything = TapReport.entry(owner: "x", isOurs: false, mask: ~0,
                                         enabled: true, avgUsec: 1, maxUsec: 1)
        XCTAssertTrue(everything.listensToKeys && everything.listensToPointer)
    }
}
