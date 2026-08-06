import Foundation

/// What Marduk last said, kept so `rr` can say it again.
///
/// Speech is the only output this product has, and it is gone the instant
/// it finishes. Every other channel a sighted user relies on to recover a
/// missed message — scrollback, a notification centre, glancing back at the
/// screen — does not exist here. A stock alert, a dialog title, or a whole
/// article read is heard once or not at all.
///
/// `rr` in NORMAL is the recovery gesture: say the last thing again. The
/// choice of "last thing SPOKEN" rather than "last announcement" is the
/// user's (2026-08-06) — an `r`/`R`/Option+Escape read is speech too, and
/// having to re-select text or re-aim the pointer to hear a paragraph twice
/// is exactly the friction the gesture exists to remove.
///
/// ONE slot, not a ring: the gesture has no forward/back walk, so entries
/// older than the newest would be unreachable, and a ring of `.paged`
/// entries would pin several whole documents in memory for nothing.
///
/// Pure value type, like `JumpList` and `BurstPolicy`: the engine owns the
/// speaking, this owns only what is worth repeating.
struct SpeechLog {

    /// A replayable utterance. The cases are not interchangeable — each
    /// must go back out through the SAME path that produced it, or the
    /// replay is a different thing than what was heard. An announcement
    /// replayed as a read would engage the reading capture over a status
    /// line; a paged read replayed as plain text would lose its page
    /// numbers, Ctrl+F/B, and every window past the first.
    enum Entry: Equatable {
        /// Status speech (`announce`): stock alerts, dialog titles, the
        /// time, update lines. Short, and replayed over the echo channel.
        case announcement(String)
        /// A plain read (`r`, `R`, Option+Escape) under the window budget.
        /// `start` is the RAW offset the read began at, so a replay starts
        /// where the original did rather than at the top of the document.
        case read(text: String, start: Int)
        /// A paged read — a real PDF, or a long text chunked into synthetic
        /// pages. Replayed from its ORIGINAL start page: `rr` repeats the
        /// read that happened, it does not resume the page you wandered to.
        ///
        /// `headings` rides along because the outline is derived by the
        /// CALLER (the daemon parses the PDF outline) and handed in — a
        /// replay that dropped it would relaunch the read with `]]`/`[[`
        /// silently dead, which is precisely the quiet degradation this
        /// codebase treats as worse than an honest failure.
        case paged(document: PagedText, page: Int, synthetic: Bool,
                   headings: [PageHeading])
    }

    /// A PDF outline entry, in the shape `speakPaged` accepts. A named
    /// Equatable type rather than the caller's tuple purely so `Entry` can
    /// synthesize Equatable (tuples cannot conform).
    struct PageHeading: Equatable {
        let page: Int
        let level: Int
    }

    private var entry: Entry?

    /// Record the utterance `rr` would repeat, replacing any earlier one.
    ///
    /// Whitespace-only announcements are dropped rather than stored: they
    /// are inaudible, so storing one would make `rr` answer a real message
    /// with silence — worse than the honest buzz an empty log gets. Reads
    /// are stored as given; the engine has already proven them speakable.
    mutating func record(_ entry: Entry) {
        if case .announcement(let text) = entry,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        self.entry = entry
    }

    /// What `rr` should say. Non-consuming: the entry survives so a second
    /// `rr` later repeats it again, which is what a user who missed it
    /// twice expects.
    func replay() -> Entry? { entry }
}
