import Foundation

/// Signs the freshly built binary so its TCC identity survives rebuilds.
/// Unsigned binaries are identified by code hash — every `swift build`
/// silently invalidates the Accessibility grant. A certificate-based
/// signature with a stable identifier is checked by chain + identifier
/// instead, so one grant lasts. Uses the first code-signing identity in
/// the keychain (Developer ID preferred, then Apple Development).
enum Codesign {
    static let identifier = "com.marduk.daemon"

    /// Signs the binary at `path` (symlinks resolved). Not finding an
    /// identity or failing to sign is non-fatal — the binary still runs,
    /// just with the TCC-fragile unsigned identity — but always logged.
    @discardableResult
    static func sign(binaryAt path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
        guard FileManager.default.fileExists(atPath: resolved) else {
            fputs("[sign] binary not found: \(resolved)\n", stderr)
            return false
        }
        guard let identity = findIdentity() else {
            fputs("[sign] no code-signing identity in keychain — skipping "
                + "(Accessibility grant will break on rebuilds)\n", stderr)
            return false
        }

        // Sign a copy and atomically swap it in. Re-signing a binary in
        // place can get any process currently running from it killed (the
        // daemon — or this very CLI when no rebuild preceded the sign);
        // the swap leaves running processes on the old inode.
        let temp = resolved + ".signing"
        let fm = FileManager.default
        try? fm.removeItem(atPath: temp)
        do {
            try fm.copyItem(atPath: resolved, toPath: temp)
        } catch {
            fputs("[sign] copy failed: \(error.localizedDescription)\n", stderr)
            return false
        }

        let result = run("/usr/bin/codesign",
                         "--force", "--sign", identity,
                         "--identifier", identifier,
                         "--timestamp=none", temp)
        guard result.status == 0 else {
            fputs("[sign] codesign failed: \(result.output)\n", stderr)
            try? fm.removeItem(atPath: temp)
            return false
        }

        do {
            _ = try fm.replaceItemAt(URL(fileURLWithPath: resolved),
                                     withItemAt: URL(fileURLWithPath: temp))
        } catch {
            fputs("[sign] swap failed: \(error.localizedDescription)\n", stderr)
            try? fm.removeItem(atPath: temp)
            return false
        }
        fputs("[sign] signed with \"\(identity)\"\n", stderr)
        return true
    }

    /// Signs an assembled .app bundle — one codesign call seals the nested
    /// executable. No copy-swap needed here: this is only ever called on
    /// the Marduk.app.new STAGING directory, which nothing executes from
    /// (the swap discipline lives in Bundler). The explicit --identifier
    /// keeps the designated requirement identical to the old bare-binary
    /// signature, which is what may let existing TCC grants survive the
    /// bundle migration.
    @discardableResult
    static func sign(bundleAt path: String) -> Bool {
        guard let identity = findIdentity() else {
            fputs("[sign] no code-signing identity in keychain — bundle "
                + "unsigned (Accessibility grant will break on rebuilds)\n", stderr)
            return false
        }
        let result = run("/usr/bin/codesign",
                         "--force", "--sign", identity,
                         "--identifier", identifier,
                         "--timestamp=none", path)
        if result.status == 0 {
            fputs("[sign] bundle signed with \"\(identity)\"\n", stderr)
            return true
        }
        fputs("[sign] bundle codesign failed: \(result.output)\n", stderr)
        return false
    }

    /// First valid code-signing identity, preferring the longer-lived kinds.
    private static func findIdentity() -> String? {
        let result = run("/usr/bin/security", "find-identity", "-v", "-p", "codesigning")
        guard result.status == 0 else { return nil }
        return firstIdentity(inSecurityOutput: result.output)
    }

    /// Pick the best signing identity out of `security find-identity`
    /// output. Pure, because the PREFERENCE ORDER is load-bearing and
    /// invisible: only a Developer ID Application certificate can produce
    /// a build that satisfies `ReleaseUpdater.requirement`, so picking an
    /// Apple Development identity when a Developer ID exists silently
    /// makes releases unverifiable.
    static func firstIdentity(inSecurityOutput output: String) -> String? {
        // Lines look like:   1) ABCD1234... "Apple Development: Your Name (TEAMID)"
        let names = output.split(separator: "\n").compactMap { line -> String? in
            guard let start = line.firstIndex(of: "\""),
                  let end = line.lastIndex(of: "\""), start < end else { return nil }
            return String(line[line.index(after: start)..<end])
        }
        for prefix in ["Developer ID Application", "Apple Development", "Mac Developer"] {
            if let match = names.first(where: { $0.hasPrefix(prefix) }) { return match }
        }
        return names.first
    }

    private static func run(_ launchPath: String, _ args: String...) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (-1, "Failed to launch \(launchPath): \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
