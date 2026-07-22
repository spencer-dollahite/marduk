import XCTest
@testable import marduk

/// Vim jumplist semantics.
///
/// This exists because a user could not get back to where a read started
/// after two jumps in a 1,336-page Terminal scrollback. The bookkeeping is
/// small but every rule in it is one someone eventually hits — a
/// mis-adjusted cursor after eviction, or a forward branch that survives a
/// new jump, both present as "Ctrl+O took me somewhere random".
final class JumpListTests: XCTestCase {

    private let session = 1
    private func at(_ offset: Int) -> JumpList.Position { .plain(offset: offset) }

    private func list(_ offsets: [Int]) -> JumpList {
        var list = JumpList()
        for offset in offsets { list.record(at(offset), session: session) }
        return list
    }

    // MARK: - Walking back and forward

    func testBackWalksNewestFirst() {
        var list = list([10, 20, 30])
        XCTAssertEqual(list.back(from: at(40)), at(30))
        XCTAssertEqual(list.back(from: at(40)), at(20))
        XCTAssertEqual(list.back(from: at(40)), at(10))
    }

    /// The whole point: N jumps then N presses of Ctrl+O reaches the start.
    func testRoundTripReturnsToTheOldestThenBack() {
        var list = list([1, 2, 3, 4, 5])
        for expected in [5, 4, 3, 2, 1] {
            XCTAssertEqual(list.back(from: at(99)), at(expected))
        }
        // …and Ctrl+I retraces it, ending at where Ctrl+O began
        for expected in [2, 3, 4, 5, 99] {
            XCTAssertEqual(list.forward(), at(expected))
        }
    }

    /// Ctrl+O from the newest end must stash the CURRENT position, or
    /// Ctrl+I has nowhere to return to.
    func testBackStashesTheCurrentPositionSoForwardCanReturn() {
        var list = list([10])
        XCTAssertEqual(list.back(from: at(500)), at(10))
        XCTAssertEqual(list.forward(), at(500),
                       "Ctrl+I must return to where Ctrl+O was pressed")
    }

    // MARK: - Edges (vim beeps at both)

    func testNothingOlderReturnsNil() {
        var empty = JumpList()
        XCTAssertNil(empty.back(from: at(5)))
    }

    func testForwardAtTheNewestEndReturnsNil() {
        var list = list([10, 20])
        XCTAssertNil(list.forward())
        _ = list.back(from: at(30))
        XCTAssertEqual(list.forward(), at(30))
        XCTAssertNil(list.forward(), "no wrapping past the newest entry")
    }

    func testBackStopsAtTheOldestEntry() {
        var list = list([10])
        XCTAssertEqual(list.back(from: at(20)), at(10))
        XCTAssertNil(list.back(from: at(20)), "no wrapping past the oldest")
    }

    // MARK: - Recording rules

    /// A new jump discards the forward branch — this is why Ctrl+I only
    /// ever retraces a Ctrl+O you just performed.
    func testANewJumpTruncatesTheForwardBranch() {
        var list = list([10, 20, 30])
        _ = list.back(from: at(40))   // now sitting on 30
        _ = list.back(from: at(40))   // now sitting on 20
        list.record(at(77), session: session)
        XCTAssertNil(list.forward(), "the forward branch must be gone")
        XCTAssertEqual(list.back(from: at(88)), at(77))
    }

    /// Without dedupe, repeated `%` or `G` gestures fill all 100 slots
    /// with the same place and Ctrl+O stops going anywhere.
    func testRecordingAKnownPositionMovesItRatherThanDuplicating() {
        var list = list([10, 20, 30])
        list.record(at(10), session: session)
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list.back(from: at(99)), at(10))
        XCTAssertEqual(list.back(from: at(99)), at(30))
    }

    // MARK: - Capacity

    /// Eviction from the front shifts every index. If the cursor doesn't
    /// move with it, the next Ctrl+O lands somewhere unrelated — which is
    /// indistinguishable, to a listener, from the bug this feature fixes.
    func testCapacityEvictionKeepsTheCursorAligned() {
        var list = list(Array(1...(JumpList.capacity + 10)))
        XCTAssertEqual(list.count, JumpList.capacity)
        // The newest survives and is still the first thing Ctrl+O returns
        XCTAssertEqual(list.back(from: at(9999)),
                       at(JumpList.capacity + 10))
        XCTAssertEqual(list.back(from: at(9999)),
                       at(JumpList.capacity + 9))
    }

    func testEvictionDuringBackKeepsTheCursorAligned() {
        var list = list(Array(1...JumpList.capacity))
        // At capacity, back() stashes current → forces an eviction
        XCTAssertEqual(list.back(from: at(9999)), at(JumpList.capacity))
        XCTAssertEqual(list.count, JumpList.capacity)
        XCTAssertEqual(list.forward(), at(9999))
    }

    // MARK: - Sessions

    /// Offsets index a `readText` that a new read replaces wholesale, so a
    /// stale entry would jump into unrelated text.
    func testANewReadInvalidatesEveryEntry() {
        var list = list([10, 20, 30])
        list.record(at(40), session: 2)
        XCTAssertEqual(list.count, 1, "entries from the old read must be gone")
        XCTAssertEqual(list.back(from: at(50)), at(40))
        XCTAssertNil(list.back(from: at(50)))
    }

    func testAFreshListHasNothingToWalk() {
        var list = JumpList()
        XCTAssertTrue(list.isEmpty)
        XCTAssertNil(list.back(from: at(1)))
        XCTAssertNil(list.forward())
    }

    func testClearEmptiesEverything() {
        var list = list([10, 20])
        list.clear()
        XCTAssertTrue(list.isEmpty)
        XCTAssertNil(list.back(from: at(30)))
    }

    // MARK: - Paged positions

    /// A paged entry carries the GLOBAL page (survives any rebuild) plus
    /// the window it was measured in (tells the engine whether the exact
    /// offset still means anything).
    func testPagedPositionsRoundTrip() {
        var list = JumpList()
        let a = JumpList.Position.paged(page: 664, windowFirst: 655, offset: 1200)
        let b = JumpList.Position.paged(page: 1, windowFirst: 0, offset: 0)
        list.record(a, session: session)
        list.record(b, session: session)
        XCTAssertEqual(list.back(from: at(0)), b)
        XCTAssertEqual(list.back(from: at(0)), a)
    }

    /// Same page reached from a different window is NOT the same position —
    /// the offsets mean different things, so dedupe must not merge them.
    func testSamePageFromADifferentWindowIsADistinctEntry() {
        var list = JumpList()
        list.record(.paged(page: 664, windowFirst: 655, offset: 10), session: session)
        list.record(.paged(page: 664, windowFirst: 600, offset: 10), session: session)
        XCTAssertEqual(list.count, 2)
    }
}
