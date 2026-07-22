import XCTest
@testable import marduk

/// The anti-bombard invariants of progressive onboarding: a hint surfaces
/// only when unseen, enabled, not-yet-experienced, under the session cap,
/// past the cooldown, and NOT while a read is speaking. When any of those
/// fails, the coordinator stays silent (a hint that talks over a read is
/// worse than one never shown). Pure logic — no filesystem or synthesizer.
final class OnboardingTests: XCTestCase {

    // A fresh, eligible baseline; each test flips one condition.
    private func surface(seen: Bool = false, enabled: Bool = true,
                         experienced: Bool = false, sessionCount: Int = 0,
                         sinceLast: TimeInterval = 9999,
                         speaking: Bool = false) -> Bool {
        Onboarding.shouldSurface(seen: seen, enabled: enabled,
                                 experienced: experienced,
                                 sessionCount: sessionCount,
                                 sinceLast: sinceLast, speaking: speaking)
    }

    func testEligibleBaselineSurfaces() {
        XCTAssertTrue(surface())
    }

    func testSeenNeverSurfaces() {
        XCTAssertFalse(surface(seen: true))
    }

    func testDisabledSilences() {
        XCTAssertFalse(surface(enabled: false))
    }

    func testExperiencedSilences() {
        XCTAssertFalse(surface(experienced: true))
    }

    func testSpeakingDefers() {
        XCTAssertFalse(surface(speaking: true),
                       "a hint must never interrupt an active read")
    }

    func testSessionCapHolds() {
        XCTAssertTrue(surface(sessionCount: Onboarding.sessionCap - 1))
        XCTAssertFalse(surface(sessionCount: Onboarding.sessionCap))
        XCTAssertFalse(surface(sessionCount: Onboarding.sessionCap + 5))
    }

    func testCooldownHolds() {
        XCTAssertFalse(surface(sinceLast: Onboarding.cooldown - 1))
        XCTAssertTrue(surface(sinceLast: Onboarding.cooldown))
        XCTAssertTrue(surface(sinceLast: Onboarding.cooldown + 1))
    }

    func testPacingConstantsAreConservative() {
        // The user asked to spread hints out — keep the defaults gentle.
        XCTAssertLessThanOrEqual(Onboarding.sessionCap, 3)
        XCTAssertGreaterThanOrEqual(Onboarding.cooldown, 60)
    }

    // MARK: - OnceMarker round-trip (uses the real ~/.config/marduk dir;
    // a uniquely-named slug keeps it isolated from real markers).

    func testOnceMarkerLifecycle() {
        let id = "test-marker-onboarding-\(ProcessInfo.processInfo.processIdentifier)"
        OnceMarker.clear(id)
        XCTAssertFalse(OnceMarker.seen(id))
        XCTAssertTrue(OnceMarker.firstTime(id), "first call is the first time")
        XCTAssertTrue(OnceMarker.seen(id))
        XCTAssertFalse(OnceMarker.firstTime(id), "second call is not")
        OnceMarker.clear(id)
        XCTAssertFalse(OnceMarker.seen(id))
    }
}
