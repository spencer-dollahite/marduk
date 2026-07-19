import Foundation

/// Manages the per-user launchd LaunchAgent that supervises the daemon:
/// autostart at login, relaunch on crash, stderr captured to a log file.
/// Pure Foundation + Process calls to /bin/launchctl.
enum LaunchAgent {
    static let label = "com.marduk.daemon"

    static var plistPath: String { NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist" }
    static var logPath: String { NSHomeDirectory() + "/Library/Logs/marduk.log" }
    static var serviceTarget: String { "gui/\(getuid())/\(label)" }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    /// Absolute, symlink-resolved path of the current executable — the path
    /// the plist must reference, and the one TCC's Accessibility grant is
    /// tied to. Nil if it doesn't resolve to an executable file.
    static func resolvedBinaryPath() -> String? {
        let raw = Bundle.main.executablePath ?? CommandLine.arguments[0]
        var url = URL(fileURLWithPath: raw)
        if !raw.hasPrefix("/") {
            url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(raw)
        }
        let resolved = url.resolvingSymlinksInPath().standardized.path
        guard FileManager.default.isExecutableFile(atPath: resolved) else { return nil }
        return resolved
    }

    /// Writes the plist and (re)bootstraps the service. Idempotent: an
    /// already-loaded service is booted out first so a changed binary path
    /// or plist takes effect.
    static func install(binaryPath: String) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try fm.createDirectory(atPath: (logPath as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
        } catch {
            fputs("[agent] Failed to create directories: \(error.localizedDescription)\n", stderr)
            return false
        }

        truncateLogIfHuge()

        // The daemon must run inline under launchd (--foreground), or the
        // spawned instance would take the kickstart path against its own
        // service. KeepAlive on SuccessfulExit=false: crash/non-zero exit →
        // relaunch (launchd throttles rapid loops ~10s); clean exit 0
        // (marduk stop) stays stopped until next login or kickstart.
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binaryPath, "start", "--foreground"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
            "ProcessType": "Interactive",
        ]
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
        } catch {
            fputs("[agent] Failed to write plist: \(error.localizedDescription)\n", stderr)
            return false
        }

        _ = launchctl("bootout", serviceTarget)  // not-loaded failure is fine
        let bootstrap = launchctl("bootstrap", "gui/\(getuid())", plistPath)
        guard bootstrap.status == 0 else {
            fputs("[agent] bootstrap failed: \(bootstrap.output)\n", stderr)
            return false
        }
        _ = launchctl("enable", serviceTarget)
        return true
    }

    /// Boots the service out (SIGTERM → the daemon's graceful shutdown) and
    /// removes the plist. Safe when not loaded.
    static func uninstall() {
        _ = launchctl("bootout", serviceTarget)
        try? FileManager.default.removeItem(atPath: plistPath)
    }

    /// Starts the service; kill:true restarts a running one. Re-bootstraps
    /// if the plist exists but the service was booted out by hand.
    @discardableResult
    static func kickstart(kill: Bool = false) -> Bool {
        truncateLogIfHuge()
        let args = kill ? ["kickstart", "-k", serviceTarget] : ["kickstart", serviceTarget]
        var result = launchctl(args)
        if result.status != 0 {
            let bootstrap = launchctl("bootstrap", "gui/\(getuid())", plistPath)
            guard bootstrap.status == 0 else {
                fputs("[agent] kickstart failed: \(result.output)\n", stderr)
                return false
            }
            _ = launchctl("enable", serviceTarget)
            result = launchctl("kickstart", serviceTarget)
        }
        return result.status == 0
    }

    /// "state = running, pid = 123" extracted from `launchctl print`, or nil
    /// when the service isn't loaded.
    static func state() -> String? {
        let result = launchctl("print", serviceTarget)
        guard result.status == 0 else { return nil }
        // launchctl print repeats "state =" for sub-components — keep only
        // the first state and pid lines.
        let lines = result.output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let parts = [lines.first { $0.hasPrefix("state = ") },
                     lines.first { $0.hasPrefix("pid = ") }].compactMap { $0 }
        return parts.isEmpty ? "loaded" : parts.joined(separator: ", ")
    }

    /// launchd appends to the log forever; cheap unbounded-growth guard
    /// (real rotation is out of scope).
    private static func truncateLogIfHuge() {
        let maxBytes: UInt64 = 10 * 1024 * 1024
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
              let size = attrs[.size] as? UInt64, size > maxBytes,
              let handle = FileHandle(forWritingAtPath: logPath) else { return }
        try? handle.truncate(atOffset: 0)
        try? handle.close()
        fputs("[agent] Truncated \(logPath) (was \(size / 1_048_576) MB)\n", stderr)
    }

    private static func launchctl(_ args: String...) -> (status: Int32, output: String) {
        launchctl(args)
    }

    private static func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (-1, "Failed to launch launchctl: \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
