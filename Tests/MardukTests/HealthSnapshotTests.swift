import XCTest
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
