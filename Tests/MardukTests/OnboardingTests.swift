import XCTest
@testable import marduk

/// The anti-bombard invariants of progressive onboarding: a hint surfaces
/// only when unseen, enabled, not-yet-experienced, under the session cap,
/// past the cooldown, and NOT while a read is speaking. When any of those
/// fails, the coordinator stays silent (a hint that talks over a read is
/// worse than one never shown). Pure logic — no filesystem or synthesizer.
final class OnboardingTests: XCTestCase {

    // A fresh, eligible baseline; each test flips one condition.
    // Derived from the constant, never a literal: the cooldown is now
    // measured in days, and a hardcoded baseline silently stopped
    // clearing it when that changed.
    private func surface(seen: Bool = false, enabled: Bool = true,
                         experienced: Bool = false, sessionCount: Int = 0,
                         sinceLast: TimeInterval = Onboarding.cooldown + 1,
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
        // "Low and slow… space things out a LOT, like over several DAYS"
        // (user ruling 2026-07-22). At most one per session, and the gap
        // between hints is measured in days — which only works because
        // lastHintAt is persisted to config across restarts.
        XCTAssertLessThanOrEqual(Onboarding.sessionCap, 1)
        XCTAssertGreaterThanOrEqual(Onboarding.cooldown, 24 * 60 * 60)
    }

    // MARK: - The hint catalog (order IS the priority)

    func testCatalogIsOrderedCriticalFirst() {
        let ids = Onboarding.catalog.map(\.id)
        // Controlling a read must come before advanced motions and before
        // niche comfort settings — a new user learns to pause and stop
        // long before they hear about spelling or rate nudging.
        guard let motions = ids.firstIndex(of: "hint-read-motions"),
              let spell = ids.firstIndex(of: "hint-spell"),
              let speed = ids.firstIndex(of: "hint-speed-keys") else {
            return XCTFail("core hints missing from the catalog")
        }
        XCTAssertLessThan(motions, spell)
        XCTAssertLessThan(spell, speed)
    }

    func testCatalogIDsAreUnique() {
        let ids = Onboarding.catalog.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count,
                       "a duplicate id would let one hint burn another's marker")
    }

    /// Every hint must be reachable: a context no call site ever claims
    /// would silently strand it (the dead-emitter trap that left the whole
    /// hint tier unreachable before).
    func testEveryHintHasAClaimableContext() {
        let claimed: Set<Onboarding.Context> = [.readStart, .pagedReadStart,
                                                .rateChange, .standalone]
        for hint in Onboarding.catalog {
            XCTAssertFalse(hint.contexts.isEmpty, "\(hint.id) can never fire")
            XCTAssertTrue(hint.contexts.isSubset(of: claimed),
                          "\(hint.id) has no claiming call site")
        }
    }

    func testReadingHintsExistForBothReadShapes() {
        let contexts = Onboarding.catalog.reduce(into: Set<Onboarding.Context>()) {
            $0.formUnion($1.contexts)
        }
        XCTAssertTrue(contexts.contains(.readStart))
        XCTAssertTrue(contexts.contains(.pagedReadStart),
                      "a paged read must be able to teach page keys")
    }

    /// A paged read must be able to reach BOTH the universal reading
    /// controls and the page keys — the paged path is not a second-class
    /// context that only ever hears about pages.
    func testPagedReadCanReachMotionsAndPageKeys() {
        let paged = Onboarding.catalog
            .filter { $0.contexts.contains(.pagedReadStart) }.map(\.id)
        XCTAssertTrue(paged.contains("hint-read-motions"))
        XCTAssertTrue(paged.contains("hint-page-keys"))
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
