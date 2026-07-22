import XCTest
@testable import marduk

/// The eleven-lesson tour. 176 lines, entirely untested until now — and it
/// needed no production change to test, because `announce` and `onComplete`
/// were already injected closures.
///
/// It matters because it is the first thing a brand-new user is offered.
/// A lesson that can never complete strands them mid-tour with no way to
/// tell whether they did the thing wrong or the software did.
final class TutorialTests: XCTestCase {

    private var spoken: [String] = []
    private var completions = 0
    private var tutorial: Tutorial!

    override func setUp() {
        super.setUp()
        spoken = []
        completions = 0
        tutorial = Tutorial()
        tutorial.announce = { [weak self] in self?.spoken.append($0) }
        tutorial.onComplete = { [weak self] in self?.completions += 1 }
    }

    /// Drive every lesson in order with the events a real user's actions
    /// would produce.
    private func completeEveryLesson() {
        tutorial.start()
        tutorial.handle(.mode(.insert))      // 1: i
        tutorial.handle(.mode(.normal))      // 2: held Escape
        tutorial.handle(.readFinished)       // 3: r
        tutorial.handle(.mode(.visual))      // 4: v …
        tutorial.handle(.readFinished)       //    … then r
        tutorial.handle(.pauseToggled)       // 5: Space …
        tutorial.handle(.pauseToggled)       //    … Space …
        tutorial.handle(.readFinished)       //    … and finish
        tutorial.handle(.announced("14 32")) // 6: t
        tutorial.handle(.mode(.command))     // 7: :
        tutorial.handle(.readJumped)         // 8: a reading motion
        tutorial.handle(.spelled)            // 9: z
        tutorial.handle(.readFinished)       // 10: held Escape
        tutorial.handle(.readFinished)       // 11: R
    }

    // MARK: - The whole tour

    func testEveryLessonCanBeCompleted() {
        completeEveryLesson()
        XCTAssertFalse(tutorial.isActive, "the tour must end after the last lesson")
        XCTAssertEqual(completions, 1)
    }

    /// The intro promises "Eleven short lessons". A twelfth added without
    /// updating that line makes the tour lie to a first-time user.
    func testTheTourHasExactlyTheElevenLessonsItPromises() {
        completeEveryLesson()
        // start() speaks intro + lesson 1; each completed lesson then speaks
        // its success line plus the next instruction. So 1 + 11 lines means
        // exactly eleven lessons ran.
        let promisedLessons = 11
        XCTAssertEqual(spoken.count, promisedLessons + 1,
                       "lesson count drifted from the eleven the intro promises")
        XCTAssertTrue(spoken.first?.contains("Eleven short lessons") == true)
        XCTAssertTrue(spoken.last?.contains("Tutorial complete") == true)
    }

    /// `onComplete` writes the `tutored` marker, which permanently quiets
    /// onboarding. Firing it twice would be irreversible.
    func testCompletionFiresExactlyOnce() {
        completeEveryLesson()
        tutorial.handle(.readFinished)   // stray event after the end
        XCTAssertEqual(completions, 1)
    }

    // MARK: - Lifecycle

    func testStartIsIdempotent() {
        tutorial.start()
        tutorial.start()
        XCTAssertEqual(spoken.count, 1, "a second start must not restart the tour")
    }

    func testAbortStopsAdvancing() {
        tutorial.start()
        tutorial.abort(silent: true)
        XCTAssertFalse(tutorial.isActive)
        let after = spoken.count
        tutorial.handle(.mode(.insert))
        XCTAssertEqual(spoken.count, after, "an aborted tour must ignore events")
    }

    func testAbortSpeaksUnlessSilenced() {
        tutorial.start()
        tutorial.abort(silent: false)
        XCTAssertEqual(spoken.last, "Tutorial ended.")
    }

    func testEventsBeforeStartAreIgnored() {
        tutorial.handle(.mode(.insert))
        XCTAssertTrue(spoken.isEmpty)
        XCTAssertFalse(tutorial.isActive)
    }

    /// Step state (`sawVisual`, `pauseCount`) is rebuilt per run. If it ever
    /// became static, lessons four and five would pass INSTANTLY on a second
    /// run — the user would hear two lessons fly by having done nothing.
    func testStepStateResetsBetweenRuns() {
        tutorial.start()
        tutorial.handle(.mode(.insert))
        tutorial.handle(.mode(.normal))
        tutorial.handle(.readFinished)
        tutorial.handle(.mode(.visual))     // arms lesson four's sawVisual
        tutorial.abort(silent: true)

        spoken = []
        tutorial.start()
        tutorial.handle(.mode(.insert))
        tutorial.handle(.mode(.normal))
        tutorial.handle(.readFinished)      // lesson three
        // Lesson four must NOT be satisfied by the previous run's visual
        tutorial.handle(.readFinished)
        XCTAssertEqual(spoken.count, 4,
                       "lesson four completed without a visual — step state "
                       + "leaked between runs")
    }

    // MARK: - Individual lessons that can be got wrong

    /// Lesson four needs a visual mode BEFORE the read, not just a read.
    func testLessonFourRequiresVisualModeFirst() {
        tutorial.start()
        tutorial.handle(.mode(.insert))
        tutorial.handle(.mode(.normal))
        tutorial.handle(.readFinished)      // lesson three done
        let atFour = spoken.count
        tutorial.handle(.readFinished)      // a read with no visual
        XCTAssertEqual(spoken.count, atFour, "lesson four advanced without visual")
        tutorial.handle(.mode(.visualLine)) // VISUAL LINE counts too
        tutorial.handle(.readFinished)
        XCTAssertEqual(spoken.count, atFour + 1)
    }

    /// Lesson five needs pause AND resume — two toggles — then the finish.
    func testLessonFiveRequiresBothPauseAndResume() {
        tutorial.start()
        tutorial.handle(.mode(.insert))
        tutorial.handle(.mode(.normal))
        tutorial.handle(.readFinished)
        tutorial.handle(.mode(.visual))
        tutorial.handle(.readFinished)
        let atFive = spoken.count

        tutorial.handle(.pauseToggled)      // paused only
        tutorial.handle(.readFinished)
        XCTAssertEqual(spoken.count, atFive, "one toggle is not pause AND resume")

        tutorial.handle(.pauseToggled)      // now two
        tutorial.handle(.readFinished)
        XCTAssertEqual(spoken.count, atFive + 1)
    }

    /// Lesson six recognises a spoken time by heuristic. It is the most
    /// fragile predicate in the file — a reworded announcement elsewhere can
    /// silently satisfy or starve it.
    func testLessonSixRecognisesSpokenTimesAndRejectsChatter() {
        func reachesSix(_ announcement: String) -> Bool {
            let t = Tutorial()
            var lines: [String] = []
            t.announce = { lines.append($0) }
            t.start()
            t.handle(.mode(.insert)); t.handle(.mode(.normal))
            t.handle(.readFinished)
            t.handle(.mode(.visual)); t.handle(.readFinished)
            t.handle(.pauseToggled); t.handle(.pauseToggled); t.handle(.readFinished)
            let before = lines.count
            t.handle(.announced(announcement))
            return lines.count > before
        }
        XCTAssertTrue(reachesSix("14 32"), "a 24-hour time must count")
        XCTAssertTrue(reachesSix("oh 9 oh 5"), "an 'oh'-prefixed time must count")
        XCTAssertFalse(reachesSix("3 j"), "short command echo must not count")
        XCTAssertFalse(reachesSix("rate"), "an ordinary word must not count")
        XCTAssertFalse(reachesSix(""), "empty announcements must not count")
    }

    // MARK: - Ordering

    /// The index advances BEFORE the success line is spoken, so an event
    /// arriving during that announcement evaluates against the NEXT lesson
    /// and can never re-fire the one just finished.
    func testAnEventDuringTheSuccessLineCannotRefireTheSameLesson() {
        let t = Tutorial()
        var lines: [String] = []
        var reentered = 0
        t.announce = { line in
            lines.append(line)
            // Re-enter exactly as a real event arriving mid-announcement would
            if reentered == 0 {
                reentered += 1
                t.handle(.mode(.insert))   // lesson one's own trigger
            }
        }
        t.start()
        t.handle(.mode(.insert))
        // Lesson one completes once; the re-entrant .insert must not complete
        // it again (lesson two wants .normal).
        XCTAssertEqual(lines.count, 2, "a lesson re-fired on a re-entrant event")
    }

    /// Out-of-order events simply do nothing — wrong keys must never
    /// advance a lesson, which is the tour's founding rule.
    func testWrongEventsNeverAdvance() {
        tutorial.start()
        for event in [Tutorial.Event.readJumped, .spelled, .pauseToggled,
                      .mode(.command), .announced("hello")] {
            tutorial.handle(event)
        }
        XCTAssertEqual(spoken.count, 1, "only lesson one's instruction so far")
    }
}
