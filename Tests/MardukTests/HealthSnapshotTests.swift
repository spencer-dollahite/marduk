import XCTest
import CoreGraphics
@testable import marduk

/// The health heartbeat exists because a multi-day slowdown left NO trace
/// in the log — no timestamps, no memory, nothing that grows. These tests
/// cover the half that can be tested off-hardware: the reading's formatting.
/// The measuring half (mach/libproc) needs a live process and stays a
/// hardware concern, like every other wide system call in this codebase.
final class HealthSnapshotTests: XCTestCase {

    private func snapshot(
        timestamp: String = "2026-08-20 14:03:11",
        uptime: TimeInterval = 3600,
        footprintBytes: UInt64 = 128 * 1024 * 1024,
        threads: Int = 9,
        openFiles: Int = 74,
        speechServiceBytes: UInt64? = 512 * 1024 * 1024,
        speechServiceCount: Int = 1,
        utterances: Int = 1108,
        synthesizerRebuilds: Int = 412
    ) -> HealthSnapshot {
        HealthSnapshot(
            timestamp: timestamp, uptime: uptime, footprintBytes: footprintBytes,
            threads: threads, openFiles: openFiles,
            speechServiceBytes: speechServiceBytes,
            speechServiceCount: speechServiceCount,
            utterances: utterances, synthesizerRebuilds: synthesizerRebuilds)
    }

    // MARK: - Sizes

    func testMegabytesBelowAGigabyte() {
        XCTAssertEqual(HealthSnapshot.size(128 * 1024 * 1024), "128 MB")
    }

    func testGigabytesAboveTheThreshold() {
        XCTAssertEqual(HealthSnapshot.size(2 * 1024 * 1024 * 1024), "2.0 GB")
    }

    func testZeroIsStillReported() {
        // A failed footprint read reports 0 rather than vanishing — a
        // missing field would look like a shorter line, not a failure.
        XCTAssertEqual(HealthSnapshot.size(0), "0 MB")
    }

    // MARK: - Durations

    func testDurationDays() {
        XCTAssertEqual(HealthSnapshot.duration(3 * 86400 + 4 * 3600), "3d 4h")
    }

    func testDurationHours() {
        XCTAssertEqual(HealthSnapshot.duration(2 * 3600 + 11 * 60), "2h 11m")
    }

    func testDurationMinutes() {
        XCTAssertEqual(HealthSnapshot.duration(14 * 60 + 30), "14m")
    }

    func testDurationSeconds() {
        XCTAssertEqual(HealthSnapshot.duration(45), "45s")
    }

    func testDurationNeverGoesNegative() {
        // Clock changes happen; a negative uptime must not print "-1d".
        XCTAssertEqual(HealthSnapshot.duration(-500), "0s")
    }

    func testDurationShowsAtMostTwoUnits() {
        // The question is "roughly how long", never "how long".
        let line = HealthSnapshot.duration(3 * 86400 + 4 * 3600 + 17 * 60 + 9)
        XCTAssertEqual(line, "3d 4h")
    }

    // MARK: - The line

    func testLineCarriesEveryField() {
        let line = snapshot().line
        XCTAssertTrue(line.hasPrefix("[health] "), line)
        XCTAssertTrue(line.contains("2026-08-20 14:03:11"), line)
        XCTAssertTrue(line.contains("up 1h 0m"), line)
        XCTAssertTrue(line.contains("128 MB"), line)
        XCTAssertTrue(line.contains("9 threads"), line)
        XCTAssertTrue(line.contains("74 fds"), line)
        XCTAssertTrue(line.contains("speech service 512 MB"), line)
        XCTAssertTrue(line.contains("1108 utterances"), line)
        XCTAssertTrue(line.contains("412 rebuilds"), line)
    }

    func testAbsentSpeechServiceSaysSoRatherThanGoingQuiet() {
        // "not running" and "0 MB" are different facts, and a reader
        // chasing a leak in the speech service must be able to tell them
        // apart — a missing service is why the number is missing.
        let line = snapshot(speechServiceBytes: nil, speechServiceCount: 0).line
        XCTAssertTrue(line.contains("speech service not running"), line)
        XCTAssertFalse(line.contains("0 MB"), line)
    }

    func testMultipleSpeechProcessesAreCounted() {
        // The footprints are summed, so the line must say how many were
        // summed or a jump from one process to two reads as a leak.
        let line = snapshot(speechServiceBytes: 900 * 1024 * 1024,
                            speechServiceCount: 3).line
        XCTAssertTrue(line.contains("(3 procs)"), line)
    }

    func testSingleSpeechProcessDoesNotSayProcs() {
        XCTAssertFalse(snapshot(speechServiceCount: 1).line.contains("procs"))
    }

    // MARK: - Privacy (the allowlist rule)

    func testNoFieldCanCarryUserContent() {
        // The log is designed to be pasted into public GitHub issues, and
        // this line is assembled from the snapshot's own fields — so the
        // guard belongs on the FIELDS, not on the rendered string (a spot
        // check of today's output would pass forever while a new field
        // quietly leaked). Reflect over every stored property: the only
        // text permitted is the timestamp. A future `frontApp`,
        // `documentTitle` or `feedURL` fails here the moment it is added.
        let mirror = Mirror(reflecting: snapshot())
        var sawTimestamp = false
        for child in mirror.children {
            guard let label = child.label else { continue }
            if label == "timestamp" {
                sawTimestamp = true
                continue
            }
            XCTAssertFalse(child.value is String,
                           "\(label) is text — the health line may carry "
                           + "counts, sizes and times only")
        }
        XCTAssertTrue(sawTimestamp, "the timestamp exemption matched nothing "
                      + "— did the field get renamed?")
    }

    func testRenderedLineCarriesNoPaths() {
        // Cheap backstop for the one shape that would survive the field
        // check: a number formatted out of a path or URL.
        XCTAssertFalse(snapshot().line.contains("/"))
    }

    // MARK: - The second round: rates, lag, and the trigger

    func testCPUAndMainLagRideTheFirstLine() {
        var s = snapshot()
        s.cpuPercent = 0.37
        s.mainLagMaxSeconds = 1.234
        XCTAssertTrue(s.line.contains("cpu 0.4%"), s.line)
        XCTAssertTrue(s.line.contains("main lag 1.23s"), s.line)
    }

    func testFirstReadingHasNoRateAndSaysNothingAboutIt() {
        // A rate needs two points; "cpu 0.0%" on the first line would
        // read as a measurement that was never taken.
        var s = snapshot()
        s.cpuPercent = nil
        XCTAssertFalse(s.line.contains("cpu "), s.line)
    }

    func testTriggeredReadingsAreLabeledAndScheduledOnesAreNot() {
        var s = snapshot()
        XCTAssertFalse(s.line.contains("("), "a scheduled reading carries no label")
        s.trigger = .wake
        XCTAssertTrue(s.line.contains("2026-08-20 14:03:11 (wake) —"), s.line)
        s.trigger = .unlocked
        XCTAssertTrue(s.line.contains("(unlocked)"), s.line)
    }

    func testRateIsPercentOfOneCoreOverTheInterval() {
        let earlier = Date(timeIntervalSince1970: 1000)
        let later = Date(timeIntervalSince1970: 1000 + 3600)
        // 36 CPU seconds over an hour = 1% of a core
        let rate = HealthMonitor.rate(now: 136, at: later, previous: (100, earlier))
        XCTAssertEqual(rate ?? -1, 1.0, accuracy: 0.001)
        XCTAssertNil(HealthMonitor.rate(now: 136, at: later, previous: nil),
                     "no previous point, no rate")
        XCTAssertNil(HealthMonitor.rate(now: 50, at: later, previous: (100, earlier)),
                     "a clock that went backwards is not a rate")
        XCTAssertNil(HealthMonitor.rate(now: 136, at: earlier, previous: (100, earlier)),
                     "zero wall time is not an interval")
    }

    // MARK: - The system line

    private func systemSnapshot() -> HealthSnapshot {
        var s = snapshot()
        s.eventTaps = 4
        s.ownTapAvgUsec = 41
        s.ownTapMaxUsec = 1234
        s.foreignPointerTaps = 1
        s.windowServerBytes = UInt64(1.4 * 1024 * 1024 * 1024)
        s.windowServerCPUPercent = 2.06
        s.systemUsedBytes = UInt64(12.1 * 1024 * 1024 * 1024)
        s.systemTotalBytes = 16 * 1024 * 1024 * 1024
        s.compressedBytes = 3 * 1024 * 1024 * 1024
        s.swapUsedBytes = 1200 * 1024 * 1024
        s.pressureLevel = 2
        s.axFlagsHeld = 0
        s.axRegistrations = 812
        s.axDeregistrations = 812
        return s
    }

    func testSystemLineCarriesThePointerPathAndTheMachine() {
        let line = systemSnapshot().systemLine
        XCTAssertTrue(line.hasPrefix("[health] system: "), line)
        XCTAssertTrue(line.contains("taps 4 (ours avg 41µs max 1.2ms, 1 foreign pointer tap)"), line)
        XCTAssertTrue(line.contains("WindowServer 1.4 GB 2.1% cpu"), line)
        XCTAssertTrue(line.contains("memory 12.1 GB of 16.0 GB used"), line)
        XCTAssertTrue(line.contains("3.0 GB compressed"), line)
        XCTAssertTrue(line.contains("1.2 GB swap"), line)
        XCTAssertTrue(line.contains("pressure warn"), line)
        XCTAssertTrue(line.contains("ax flags held 0"), line)
        XCTAssertTrue(line.contains("ax observers 812/812"), line)
    }

    func testUnreadableSystemFactsSaySoRatherThanReadingAsZero() {
        // "unreadable" and "0" are different facts — WindowServer runs as
        // another user and may refuse; a zero would read as an idle server.
        var s = systemSnapshot()
        s.eventTaps = 0
        s.windowServerBytes = nil
        s.windowServerCPUPercent = nil
        s.systemTotalBytes = 0
        let line = s.systemLine
        XCTAssertTrue(line.contains("taps unreadable"), line)
        XCTAssertTrue(line.contains("WindowServer unreadable"), line)
        XCTAssertFalse(line.contains("memory"), line)
        XCTAssertFalse(line.contains("pressure"), line)
    }

    func testOurTapMissingFromTheListIsItsOwnFinding() {
        var s = systemSnapshot()
        s.ownTapAvgUsec = nil
        s.ownTapMaxUsec = nil
        XCTAssertTrue(s.systemLine.contains("taps 4 (ours not found)"), s.systemLine)
    }

    func testNoForeignPointerTapsIsStatedNotOmitted() {
        var s = systemSnapshot()
        s.foreignPointerTaps = 0
        XCTAssertTrue(s.systemLine.contains("no foreign pointer taps"), s.systemLine)
    }

    func testPressureNames() {
        XCTAssertEqual(HealthSnapshot.pressureName(1), "normal")
        XCTAssertEqual(HealthSnapshot.pressureName(2), "warn")
        XCTAssertEqual(HealthSnapshot.pressureName(4), "critical")
        XCTAssertEqual(HealthSnapshot.pressureName(0), "unknown")
    }

    func testMicrosecondsSwitchToMillisecondsAtAThousand() {
        XCTAssertEqual(HealthSnapshot.micros(41.4), "41µs")
        XCTAssertEqual(HealthSnapshot.micros(999), "999µs")
        XCTAssertEqual(HealthSnapshot.micros(1234), "1.2ms")
    }

    // MARK: - The tap report

    func testTapReportListsSlowestFirstAndMarksOursAndDisabled() {
        let report = TapReport(entries: [
            TapReport.entry(owner: "marduk", isOurs: true,
                            mask: 1 << CGEventType.keyDown.rawValue,
                            enabled: true, avgUsec: 40, maxUsec: 900),
            TapReport.entry(owner: "SomeUtility", isOurs: false,
                            mask: ~0, enabled: false, avgUsec: 3200, maxUsec: 48000),
        ])
        let line = report.line
        XCTAssertTrue(line.hasPrefix("[health] taps: SomeUtility keys+pointer avg 3.2ms max 48.0ms DISABLED; "), line)
        XCTAssertTrue(line.contains("marduk (us) keys avg 40µs max 900µs"), line)
        XCTAssertFalse(line.contains("marduk (us) keys avg 40µs max 900µs DISABLED"), line)
    }

    func testEmptyTapReportSaysNone() {
        XCTAssertEqual(TapReport(entries: []).line, "[health] taps: none listed")
    }

    func testTapReportNamesOnlyExecutablesNeverPaths() {
        // Owners are basenames by construction in the monitor; the report
        // itself must not grow a path-shaped field.
        let mirror = Mirror(reflecting: TapReport.Entry(
            owner: "x", isOurs: false, listensToKeys: false, listensToPointer: false,
            enabled: true, avgUsec: 0, maxUsec: 0))
        let textFields = mirror.children.filter { $0.value is String }.map { $0.label ?? "" }
        XCTAssertEqual(textFields, ["owner"], "only the executable basename may be text")
    }

    // MARK: - Cadence

    func testFirstReadingLandsWellBeforeTheHourlyBeat() {
        // A leak is a DELTA and a delta needs a first point, so a session
        // shorter than the interval must still record where it started.
        XCTAssertLessThan(HealthMonitor.firstReading, HealthMonitor.interval)
        XCTAssertLessThanOrEqual(HealthMonitor.firstReading, 300)
    }

    func testHeartbeatStaysRareEnoughNotToBuryTheLog() {
        // It shares a file with per-utterance speech logging; an hourly
        // row is a trend line, anything faster is noise in the way.
        XCTAssertGreaterThanOrEqual(HealthMonitor.interval, 1800)
    }
}
