import Foundation

/// Vim's jumplist for reading mode — Ctrl+O walks back through the places
/// you jumped from, Ctrl+I walks forward again.
///
/// Field report 2026-07-22: in a 1,336-page Terminal scrollback the user
/// pressed `50%` then `gg` and could not get back to where the read began.
/// Every read motion was one-way; `.` repeats a motion but nothing walked
/// one back. Vim's answer to exactly this problem is the jumplist, so
/// Marduk's is vim's, semantics included.
///
/// Pure value type, like `ReadNavigator` and `HoverDwell`: the engine owns
/// the positions, this owns the bookkeeping.
struct JumpList {

    /// Where a jump came from.
    ///
    /// The two cases are NOT interchangeable, which is why this is an enum
    /// rather than an optional page. `offset` on a paged read is an offset
    /// into the current window's PROCESSED text, while `PagedText`'s page
    /// starts are offsets into the RAW text — so an offset only means
    /// anything while the window it was measured in is still loaded. The
    /// `windowFirst` stamp is what lets the engine tell.
    enum Position: Equatable {
        /// A plain (unwindowed) read: the offset is into `readText` and is
        /// stable for the life of the read.
        case plain(offset: Int)
        /// A paged read: `page` is 1-based and GLOBAL, so it survives any
        /// window rebuild. `offset` is usable only while `windowFirst`
        /// still matches the engine's current window.
        case paged(page: Int, windowFirst: Int, offset: Int)
    }

    /// Vim's default jumplist length.
    static let capacity = 100

    private var entries: [Position] = []
    /// Index of the NEXT entry `back()` would return. Equals `entries.count`
    /// when we are at the newest end (nothing to go forward to).
    private var cursor = 0
    /// The read these entries belong to. A new read bumps the engine's
    /// session and every entry becomes unusable — offsets index a `readText`
    /// that no longer exists.
    private var session = -1

    var isEmpty: Bool { entries.isEmpty }
    /// Exposed for tests and logging; not part of the gesture.
    var count: Int { entries.count }

    /// Record the position a jump is leaving FROM.
    ///
    /// Callers must only call this when the motion actually succeeded —
    /// vim sets its mark on a successful jump, and recording a `G` that hit
    /// the last page would make Ctrl+O a no-op that still consumed a slot.
    mutating func record(_ position: Position, session: Int) {
        if session != self.session {
            // A different read: everything here indexes text that is gone.
            entries.removeAll()
            cursor = 0
            self.session = session
        }
        // A new jump discards the forward branch — vim's behaviour, and the
        // reason Ctrl+I only ever retraces a Ctrl+O you just did.
        if cursor < entries.count {
            entries.removeSubrange(cursor...)
        }
        // Vim dedupes rather than stacking duplicates; without this,
        // repeated `%` or `G` gestures fill every slot with one place.
        if let existing = entries.firstIndex(of: position) {
            entries.remove(at: existing)
        }
        entries.append(position)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        // Always park at the newest end after recording.
        cursor = entries.count
    }

    /// Ctrl+O. `current` is where the read is NOW; at the newest end it is
    /// appended first so Ctrl+I can bring the user back to it.
    ///
    /// Returns nil when there is nothing older — vim beeps, and so do we.
    mutating func back(from current: Position) -> Position? {
        guard session != -1, cursor > 0 else { return nil }
        if cursor == entries.count {
            entries.append(current)
            if entries.count > Self.capacity {
                let dropped = entries.count - Self.capacity
                entries.removeFirst(dropped)
                // Evicting from the front shifts every index: move the
                // cursor with it or the next Ctrl+O lands somewhere random.
                cursor -= dropped
            }
        }
        cursor -= 1
        guard entries.indices.contains(cursor) else { return nil }
        return entries[cursor]
    }

    /// Ctrl+I. Returns nil at the newest end — vim beeps there too.
    mutating func forward() -> Position? {
        guard session != -1, cursor + 1 < entries.count else { return nil }
        cursor += 1
        return entries[cursor]
    }

    mutating func clear() {
        entries.removeAll()
        cursor = 0
        session = -1
    }
}
