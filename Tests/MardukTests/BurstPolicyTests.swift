import XCTest
@testable import marduk

/// The typing-rescue burst decision — the highest-consequence judgment in
/// the product, and until now completely unreachable by a test.
///
/// In NORMAL mode unmodified letters are WITHHELD ~300ms, then either
/// executed as commands or replayed into the app as typing. A wrong answer
/// either eats the user's keystrokes or fires commands while they type.
final class BurstPolicyTests: XCTestCase {

    // Keycodes, named so the cases read like the gestures they describe.
    private let s: Int64 = 1,  v: Int64 = 9,  r: Int64 = 15, t: Int64 = 17
    private let u: Int64 = 32, i: Int64 = 34, k: Int64 = 40, d: Int64 = 2
    private let n: Int64 = 45, h: Int64 = 4,  a: Int64 = 0,  j: Int64 = 38

    private func classify(_ buffer: [Int64], _ keycode: Int64,
                          isLetter: Bool = true, autorepeat: Bool = false,
                          firefox: Bool = false,
                          release: Bool = false) -> BurstPolicy.Verdict {
        BurstPolicy.classify(buffer: buffer, keycode: keycode, isLetter: isLetter,
                             isAutorepeat: autorepeat, firefoxFrontmost: firefox,
                             releaseAvailable: release)
    }

    // MARK: - The rescue itself

    /// The founding case: a word whose command letter comes second must
    /// rescue as typing, not fire a command.
    func testWordsWithALaterCommandLetterRescue() {
        // "hi" — h is not a command, so the moment i arrives it's typing
        XCTAssertEqual(classify([h], i), .declareTyping)
        // "at"
        XCTAssertEqual(classify([a], t), .declareTyping)
    }

    /// "sun" and "runs" are the documented reason `n` is only a command
    /// letter while Firefox is frontmost.
    func testAllCommandWordsRescueOnceANonCommandLetterArrives() {
        // s-u are both commands, so still ambiguous…
        XCTAssertEqual(classify([s], u), .append)
        // …but the n makes it a word (Firefox NOT frontmost)
        XCTAssertEqual(classify([s, u], n), .declareTyping)
    }

    func testNIsACommandLetterOnlyWhileFirefoxIsFrontmost() {
        XCTAssertEqual(classify([s, u], n, firefox: true), .append)
        XCTAssertEqual(classify([s, u], n, firefox: false), .declareTyping)
        // …and as a buffer HEAD it flips the same way
        XCTAssertEqual(classify([n], r, firefox: true), .append)
        XCTAssertEqual(classify([n], r, firefox: false), .declareTyping)
    }

    /// Deliberate rapid command pairs must stay commands.
    func testCommandPairsKeepCollecting() {
        XCTAssertEqual(classify([s], r), .append)
        XCTAssertEqual(classify([s, r], t), .append)
    }

    /// THE load-bearing invariant, asserted as a property rather than an
    /// argument: whenever any buffered key is a non-command letter, the
    /// verdict must be typing. The implementation only inspects the HEAD
    /// plus the incoming key, justified by "a non-command letter can only
    /// ever sit at position 0" — this is what proves that reasoning holds.
    func testAnyNonCommandLetterInTheBufferMeansTyping() {
        let letters: [Int64] = [a, h, j, s, v, r, t, u, i, n, d]
        for head in letters {
            for incoming in letters {
                let verdict = classify([head], incoming)
                let headIsCommand = BurstPolicy.isCommandLetter(head, firefoxFrontmost: false)
                let inIsCommand = BurstPolicy.isCommandLetter(incoming, firefoxFrontmost: false)
                // Double taps and v+motion resolve before the typing test
                let isDoubleTap = (head == incoming) && (incoming == t || incoming == u)
                let isVisualMotion = head == v && BurstPolicy.visualMotionKeys.contains(incoming)
                if isDoubleTap || isVisualMotion { continue }
                if headIsCommand && inIsCommand {
                    XCTAssertEqual(verdict, .append, "\(head)+\(incoming)")
                } else {
                    XCTAssertEqual(verdict, .declareTyping,
                                   "buffer \(head) + \(incoming) must rescue as typing")
                }
            }
        }
    }

    // MARK: - Double taps

    func testDoubleTapsResolveAgainstABufferedTwin() {
        XCTAssertEqual(classify([t], t), .doubleTap(.time))
        XCTAssertEqual(classify([u], u), .doubleTap(.update))
    }

    /// The prefix must survive: the `s` in `s-t-t` is a real command.
    func testDoubleTapStillMatchesBehindAPrefix() {
        XCTAssertEqual(classify([s, t], t), .doubleTap(.time))
        XCTAssertEqual(classify([s, u], u), .doubleTap(.update))
    }

    /// A double tap needs the twin ADJACENT — `t` then `u` then `t` is not
    /// a `tt`.
    func testDoubleTapNeedsTheImmediatelyPrecedingKey() {
        XCTAssertEqual(classify([t, u], t), .append)
    }

    /// On a release or Homebrew install the release gesture DOES NOT
    /// EXIST, so double-d words keep their typing rescue and a stranger's
    /// machine has zero surface for it.
    func testReleaseGestureOnlyExistsOnSourceInstalls() {
        XCTAssertEqual(classify([d], d, release: true), .doubleTap(.release))
        // Without a source install, d is an ordinary (non-command) letter
        XCTAssertEqual(classify([d], d, release: false), .declareTyping)
    }

    /// A first `t` on an empty buffer starts a burst — it cannot be a
    /// double tap with nothing to pair against.
    func testFirstOfAPairJustStartsTheBuffer() {
        XCTAssertEqual(classify([], t), .startBuffer)
        XCTAssertEqual(classify([], u), .startBuffer)
        XCTAssertEqual(classify([], d, release: true), .startBuffer)
    }

    // MARK: - v + motion

    func testVisualMotionAfterVFlushesImmediately() {
        for motion in BurstPolicy.visualMotionKeys {
            XCTAssertEqual(classify([v], motion), .flushThenRedispatch,
                           "v + \(motion) must enter visual with no latency")
        }
    }

    /// The v must be the buffer HEAD; a motion after some other command
    /// is not the visual gesture.
    func testVisualMotionOnlyAppliesWhenVLeadsTheBuffer() {
        XCTAssertEqual(classify([s], j), .declareTyping)  // j isn't a command letter
        XCTAssertEqual(classify([v, r], j), .flushThenRedispatch)  // v still leads
    }

    // MARK: - The two keys with special lifecycles

    /// `i` must reach INSERT with ZERO latency on an empty buffer, but
    /// mid-buffer it is a plausible deliberate command.
    func testIIsInstantOnlyOnAnEmptyBuffer() {
        XCTAssertEqual(classify([], i), .passThrough)
        XCTAssertEqual(classify([s], i), .append)
    }

    /// `k` passes straight through on an empty buffer, and its autorepeat
    /// keeps flowing into the app even mid-burst (it's scroll input, not a
    /// no-op) — but arriving INTO a buffer it is an ordinary letter and
    /// means typing.
    func testKHasThreeDistinctBehaviors() {
        XCTAssertEqual(classify([], k), .passThrough)
        XCTAssertEqual(classify([s], k, autorepeat: true), .passThrough)
        XCTAssertEqual(classify([s], k), .declareTyping)
    }

    func testAutorepeatOfAnyOtherLetterIsSwallowed() {
        XCTAssertEqual(classify([s], r, autorepeat: true), .swallowRepeat)
        XCTAssertEqual(classify([], r, autorepeat: true), .swallowRepeat)
    }

    // MARK: - Non-letters

    func testNonLettersRouteNormallyWithNoBurstPending() {
        XCTAssertEqual(classify([], 49, isLetter: false), .passThrough)   // space
        XCTAssertEqual(classify([], 53, isLetter: false), .passThrough)   // escape
    }

    func testNonLettersResolveAPendingBurstFirst() {
        XCTAssertEqual(classify([s], 49, isLetter: false), .flushThenRoute)
        XCTAssertEqual(classify([v], 19, isLetter: false), .flushThenRoute)  // v then 2
    }

    /// A non-letter is never treated as typing or a double tap, whatever
    /// the buffer holds.
    func testNonLettersNeverDeclareTyping() {
        for buffer in [[], [s], [s, r], [t], [v]] as [[Int64]] {
            let verdict = classify(buffer, 49, isLetter: false)
            XCTAssertTrue(verdict == .passThrough || verdict == .flushThenRoute,
                          "a non-letter produced \(verdict)")
        }
    }

    // MARK: - Table invariants

    /// The command letters are s v r t u i. If this set grows silently,
    /// ordinary words stop rescuing.
    func testCommandLetterSetIsExactlyTheDocumentedSix() {
        XCTAssertEqual(BurstPolicy.commandLetterKeys, [s, v, r, t, u, i])
    }

    /// `oneShotNormalKeys` is derived from this set so a future command
    /// letter can't forget its autorepeat suppression.
    func testVisualMotionsAreTheVimMotionKeys() {
        XCTAssertEqual(BurstPolicy.visualMotionKeys, [h, j, k, 37, 5])
    }

    /// No verdict may withhold a key forever: every classification either
    /// resolves now or is one that the burst timer will flush.
    func testEveryVerdictIsReachable() {
        var seen = Set<String>()
        let letters: [Int64] = [a, s, v, r, t, u, i, k, d, n, h, j]
        for buffer in [[], [s], [t], [u], [d], [v], [a], [s, r]] as [[Int64]] {
            for key in letters {
                for repeatKey in [false, true] {
                    for release in [false, true] {
                        seen.insert("\(classify(buffer, key, autorepeat: repeatKey, release: release))")
                    }
                }
            }
            seen.insert("\(classify(buffer, 49, isLetter: false))")
        }
        for expected in ["passThrough", "swallowRepeat", "startBuffer", "append",
                         "declareTyping", "flushThenRedispatch", "flushThenRoute"] {
            XCTAssertTrue(seen.contains { $0.contains(expected) },
                          "\(expected) is unreachable — dead branch or wrong test matrix")
        }
    }
}
