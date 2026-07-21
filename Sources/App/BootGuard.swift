import Foundation

/// Rapid-crash detection. A daemon that crashes at STARTUP can never ship
/// its own fix — KeepAlive relaunch-loops it (throttled ~10s) and the only
/// user recovery is a manual reinstall, the worst possible failure for
/// someone who relies on Marduk to use their machine. The guard counts
/// rapid boot attempts in a marker file; at the threshold the daemon comes
/// up in SAFE MODE — speech, socket, event tap, and the UPDATE TRAIN, with
/// the riskier boot-time subsystems skipped — so whatever a future macOS
/// breaks, the fix can still arrive by pressing u.
enum BootGuard {
    static let safeModeThreshold = 3
    /// Entries older than this are a cold start, not a crash loop —
    /// KeepAlive keeps real loops ~10s apart.
    static let staleAfter: TimeInterval = 300

    /// Overridable for tests.
    nonisolated(unsafe) static var markerURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/marduk/.boot-attempts")

    /// Called once at daemon start: increments (or restarts) the rapid-boot
    /// count and returns it. `>= safeModeThreshold` means boot safe.
    @discardableResult
    static func register(now: Date = Date()) -> Int {
        let (count, stamp) = read()
        let next = (now.timeIntervalSince(stamp) < staleAfter ? count : 0) + 1
        write(count: next, at: now)
        return next
    }

    /// A boot that survives a minute — or exits cleanly — was not a crash.
    static func markStable() {
        write(count: 0, at: Date())
    }

    private static func read() -> (count: Int, stamp: Date) {
        guard let text = try? String(contentsOf: markerURL, encoding: .utf8) else {
            return (0, .distantPast)
        }
        let parts = text.split(separator: " ")
        guard parts.count == 2, let count = Int(parts[0]),
              let epoch = Double(parts[1]) else {
            return (0, .distantPast)
        }
        return (count, Date(timeIntervalSince1970: epoch))
    }

    private static func write(count: Int, at date: Date) {
        try? FileManager.default.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? "\(count) \(Int(date.timeIntervalSince1970))"
            .write(to: markerURL, atomically: true, encoding: .utf8)
    }
}
