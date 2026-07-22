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
    private static let dir = FileManager.default.homeDirectoryForCurrentUser
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
}
