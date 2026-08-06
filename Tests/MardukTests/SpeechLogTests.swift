import XCTest
@testable import marduk

/// `rr` — say the last thing again.
///
/// Speech is this product's only output and it is gone the moment it
/// finishes; there is no scrollback for a user who cannot see the screen.
/// The bookkeeping behind the gesture is tiny, but every rule in it is
/// load-bearing: store the wrong thing and `rr` answers a missed stock
/// alert with a whole document, or with silence.
final class SpeechLogTests: XCTestCase {

    private func doc(_ pages: [String]) -> PagedText { PagedText(pages: pages) }

    // MARK: - The basic contract

    func testNothingSpokenYetHasNothingToReplay() {
        XCTAssertNil(SpeechLog().replay())
    }

    func testAnAnnouncementComesBackVerbatim() {
        var log = SpeechLog()
        log.record(.announcement("AAPL, 309 dollars 86 cents, up 1.2 percent"))
        XCTAssertEqual(log.replay(),
                       .announcement("AAPL, 309 dollars 86 cents, up 1.2 percent"))
    }

    /// The gesture exists for someone who missed a message. Missing it twice
    /// is not rarer than missing it once, so the entry must survive replay.
    func testReplayDoesNotConsumeTheEntry() {
        var log = SpeechLog()
        log.record(.announcement("Update complete. Restarting."))
        XCTAssertEqual(log.replay(), .announcement("Update complete. Restarting."))
        XCTAssertEqual(log.replay(), .announcement("Update complete. Restarting."))
    }

    /// One slot, newest wins — "replay LAST speech". A read followed by a
    /// stock alert replays the alert, because that is what was last said.
    func testTheNewestUtteranceWins() {
        var log = SpeechLog()
        log.record(.read(text: "the article", start: 0))
        log.record(.announcement("Focus? a, o, n, or s."))
        XCTAssertEqual(log.replay(), .announcement("Focus? a, o, n, or s."))
    }

    // MARK: - What must NOT be stored

    /// An inaudible announcement stored is worse than none: `rr` would
    /// answer a real message with silence, which reads as a broken gesture.
    /// An empty log at least buzzes.
    func testWhitespaceOnlyAnnouncementsAreNotStored() {
        var log = SpeechLog()
        XCTAssertNil(log.replayAfterRecording(.announcement("")))
        XCTAssertNil(log.replayAfterRecording(.announcement("   \n\t ")))
    }

    /// …and a blank one must not evict a good entry that came before it.
    func testABlankAnnouncementDoesNotEvictTheLastRealOne() {
        var log = SpeechLog()
        log.record(.announcement("Systems engaged"))
        log.record(.announcement("  "))
        XCTAssertEqual(log.replay(), .announcement("Systems engaged"))
    }

    /// Reads are stored as handed over — the engine has already proven the
    /// text speakable (it survived preprocessing), so a whitespace test here
    /// would only second-guess a decision already made correctly upstream.
    func testReadsAreStoredAsGiven() {
        var log = SpeechLog()
        log.record(.read(text: "  padded but real  ", start: 3))
        XCTAssertEqual(log.replay(), .read(text: "  padded but real  ", start: 3))
    }

    // MARK: - Reads keep their start offset

    /// `rr` repeats the read that happened. A read that began at the caret
    /// must not silently restart from the top of the document.
    func testAReadRemembersWhereItStarted() {
        var log = SpeechLog()
        log.record(.read(text: "one two three four", start: 8))
        guard case .read(_, let start)? = log.replay() else {
            return XCTFail("expected a read entry")
        }
        XCTAssertEqual(start, 8)
    }

    // MARK: - Paged reads

    /// A paged read must come back paged. Replayed as plain text it would
    /// lose page numbers, Ctrl+F/B, and every window past the first — a
    /// silent downgrade, which is worse than a buzz.
    func testAPagedReadKeepsItsDocumentPageAndSyntheticFlag() {
        var log = SpeechLog()
        let pdf = doc(["page one", "page two", "page three"])
        log.record(.paged(document: pdf, page: 2, synthetic: false, headings: []))
        guard case .paged(let stored, let page, let synthetic, _)? = log.replay() else {
            return XCTFail("expected a paged entry")
        }
        XCTAssertEqual(stored, pdf)
        XCTAssertEqual(page, 2)
        XCTAssertFalse(synthetic)
    }

    /// Chunked plain text rides the same machinery but must NOT fire the
    /// viewer's go-to-page gesture — there is no viewer. The flag that says
    /// so has to survive the replay.
    func testSyntheticPagingSurvivesReplay() {
        var log = SpeechLog()
        log.record(.paged(document: doc(["a", "b"]), page: 1,
                          synthetic: true, headings: []))
        guard case .paged(_, _, let synthetic, _)? = log.replay() else {
            return XCTFail("expected a paged entry")
        }
        XCTAssertTrue(synthetic)
    }

    /// The outline is derived by the caller and handed in, so a replay that
    /// dropped it would relaunch the read with `]]`/`[[` quietly dead.
    func testPDFOutlineHeadingsSurviveReplay() {
        var log = SpeechLog()
        let headings = [SpeechLog.PageHeading(page: 1, level: 1),
                        SpeechLog.PageHeading(page: 4, level: 2)]
        log.record(.paged(document: doc(["a", "b", "c", "d"]), page: 1,
                          synthetic: false, headings: headings))
        guard case .paged(_, _, _, let stored)? = log.replay() else {
            return XCTFail("expected a paged entry")
        }
        XCTAssertEqual(stored, headings)
    }

}

private extension SpeechLog {
    /// Record into a fresh log and report what `rr` would say — keeps the
    /// rejection cases readable.
    mutating func replayAfterRecording(_ entry: SpeechLog.Entry) -> SpeechLog.Entry? {
        self = SpeechLog()
        record(entry)
        return replay()
    }
}
