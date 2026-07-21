import XCTest
@testable import marduk

final class BootGuardTests: XCTestCase {

    private var originalURL: URL!

    override func setUp() {
        super.setUp()
        originalURL = BootGuard.markerURL
        BootGuard.markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bootguard-test-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: BootGuard.markerURL)
        BootGuard.markerURL = originalURL
        super.tearDown()
    }

    func testRapidBootsCount() {
        XCTAssertEqual(BootGuard.register(), 1)
        XCTAssertEqual(BootGuard.register(), 2)
        XCTAssertEqual(BootGuard.register(), 3)
        XCTAssertGreaterThanOrEqual(3, BootGuard.safeModeThreshold)
    }

    func testStaleEntryResetsToOne() {
        BootGuard.register()
        BootGuard.register()
        // A boot far in the future sees a stale marker — cold start, not loop
        let later = Date().addingTimeInterval(BootGuard.staleAfter + 60)
        XCTAssertEqual(BootGuard.register(now: later), 1)
    }

    func testMarkStableResets() {
        BootGuard.register()
        BootGuard.register()
        BootGuard.markStable()
        XCTAssertEqual(BootGuard.register(), 1)
    }

    func testGarbageMarkerCountsAsFresh() {
        try? "not a marker".write(to: BootGuard.markerURL,
                                  atomically: true, encoding: .utf8)
        XCTAssertEqual(BootGuard.register(), 1)
    }
}
