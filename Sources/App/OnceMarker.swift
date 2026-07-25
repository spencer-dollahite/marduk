import Foundation

/// Once-ever markers: the dotfiles under ~/.config/marduk/ that gate
/// first-run and first-use behavior (the welcome, the dark-PDF
/// explanation, the Karabiner-absence tip, the dialog-focus pitch, every
/// onboarding hint). Consolidates the "build a `.NAME` path → fileExists →
/// Data().write" idiom that was copy-pasted at each site.
///
/// Presence of the file IS the state — an absent or unwritable file simply
/// means "not seen yet" (fail-soft: a hint might repeat, never crash). The
/// name is a bare slug WITHOUT the leading dot; the dot is added here so
/// call sites read cleanly (`OnceMarker.seen("welcomed")`).
enum OnceMarker {
    /// Overridable for tests — the `BootGuard.markerURL` idiom. Without a
    /// seam here, any test touching a marker writes into the DEVELOPER'S
    /// real ~/.config/marduk and can clobber their `.welcomed`/`.tutored`
    /// state. Production never assigns this.
    nonisolated(unsafe) static var dir =
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/marduk")

    private static func url(_ name: String) -> URL {
        dir.appendingPathComponent(".\(name)")
    }

    static func seen(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(name).path)
    }

    /// Record the marker. Creates the config dir if needed (first run may
    /// predate the first config save). Returns whether it is now marked.
    @discardableResult
    static func mark(_ name: String) -> Bool {
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        try? Data().write(to: url(name))
        return seen(name)
    }

    /// Forget the marker (tests; by hand, `rm ~/.config/marduk/.<name>`
    /// replays the welcome or a hint for support and development).
    static func clear(_ name: String) {
        try? FileManager.default.removeItem(at: url(name))
    }

    /// Check-and-mark in one step: true the FIRST time only. The marker is
    /// written BEFORE the caller acts, so a crash mid-action can't replay
    /// it (the welcome's founding rule).
    static func firstTime(_ name: String) -> Bool {
        guard !seen(name) else { return false }
        mark(name)
        return true
    }

    // MARK: - Counted markers
    //
    // Some guidance should FADE rather than fire exactly once: the NORMAL-mode
    // buzz explains itself the first few times and then goes quiet (the user
    // has learned what the buzzer means by then). Same dotfile, holding a
    // small decimal count instead of being empty — the `.boot-attempts`
    // idiom, minus the time window. Counts must PERSIST: an in-memory tally
    // resets on every restart, and self-updates restart the daemon often
    // enough that "the first three times" would mean "three times forever"
    // (the same trap `Onboarding.lastHintAt` fell into).

    /// The count recorded for `name`, 0 if never recorded. An existing file
    /// that doesn't parse as a number counts as 1 — a marker written by the
    /// boolean `mark` above has been "seen" once, so retrofitting counting
    /// onto a boolean marker never replays it from zero.
    static func count(_ name: String) -> Int {
        guard let text = try? String(contentsOf: url(name), encoding: .utf8) else {
            return 0
        }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
    }

    /// Record `value` as the count for `name`. Writes the caller's
    /// authoritative number rather than read-modify-writing, so a caller
    /// keeping the tally in memory (the event tap, which must never read
    /// files) can flush it from any queue without racing itself.
    static func setCount(_ name: String, _ value: Int) {
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        try? "\(value)".write(to: url(name), atomically: true, encoding: .utf8)
    }
}
