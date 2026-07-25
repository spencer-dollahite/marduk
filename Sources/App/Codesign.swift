import Foundation

/// Signs the freshly built binary so its TCC identity survives rebuilds.
/// Unsigned binaries are identified by code hash — every `swift build`
/// silently invalidates the Accessibility grant. A certificate-based
/// signature with a stable identifier is checked by chain + identifier
/// instead, so one grant lasts. Uses the first code-signing identity in
/// the keychain (Developer ID preferred, then Apple Development).
enum Codesign {
    static let identifier = "com.marduk.daemon"

    /// The ONE designated requirement, used to both PRODUCE and VERIFY every
    /// Marduk build: our bundle identifier, signed by our team's Developer
    /// ID. This is the same predicate TCC stores when the user grants
    /// Accessibility, so a build that satisfies it is the same client and
    /// keeps the grant; a build that doesn't is a stranger macOS has never
    /// seen. Kept as a literal rather than interpolating `identifier` so
    /// `DriftGuardTests` still catches the identifier moving without it.
    ///
    /// BARE TEXT — no leading `=`. codesign's `-R` takes either a FILE PATH
    /// or, if the value starts with `=`, the requirement text inline; the
    /// call sites supply that marker by joining `"-R=" + requirement`. This
    /// constant carried its own `=` until 2026-07-25, which made the joined
    /// argument `-R==identifier …`: codesign stripped one `=` as the inline
    /// marker and handed `=identifier …` to the requirement parser, which
    /// died with `line 1:1: unexpected token: =`. The gate therefore exited
    /// non-zero on EVERY run, so `ReleaseUpdater.install` always returned
    /// `.verification` and no downloaded DMG could ever self-install. The
    /// bug was invisible from here: the maintainer runs the SOURCE channel,
    /// which never calls that path, and the drift test only asserted what
    /// the string contained — never that codesign could parse it.
    static let requirement = "identifier \"com.marduk.daemon\" and anchor apple generic "
        + "and certificate leaf[subject.OU] = \"X56UYJ5NDJ\""

    /// What a signing attempt actually ACHIEVED — which is not the same fact
    /// as codesign exiting 0. Signing has always been non-fatal here (a
    /// contributor without a certificate must still be able to build); what
    /// was missing is that it was also SILENT, so a skipped or wrong-identity
    /// signature surfaced days later as a dead keyboard. An unverified bundle
    /// is identified by CODE HASH, which changes on every single rebuild —
    /// hence "I've had to re-add it several times". Toggling the existing
    /// Accessibility entry off and on does NOT fix it: the stale requirement
    /// lives in that row and only removing/re-adding (or
    /// `tccutil reset Accessibility com.marduk.daemon`) replaces it.
    enum SignOutcome: Equatable {
        case verified
        case problem(String)

        var isVerified: Bool { self == .verified }

        /// Short, spoken. Specifics stay in the log.
        static let spokenWarning = "Marduk could not be signed. Keyboard "
            + "commands may stop working until you remove Marduk from "
            + "Accessibility settings and add it again."
    }

    /// The gates a freshly signed bundle must pass. `spctl` is deliberately
    /// NOT here, unlike `ReleaseUpdater.verificationGates`: a locally signed
    /// build is not notarized, so asserting notarization would fail on every
    /// developer machine and turn the warning into noise. Signature validity
    /// plus the pinned requirement is exactly what TCC cares about.
    static func verificationGates(bundleAt path: String) -> [[String]] {
        [
            ["/usr/bin/codesign", "--verify", "--strict", "--deep", path],
            ["/usr/bin/codesign", "--verify", "-R=" + requirement, path],
        ]
    }

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
    static func sign(bundleAt path: String) -> SignOutcome {
        guard let identity = findIdentity() else {
            let reason = "no code-signing identity in keychain"
            fputs("[sign] \(reason) — bundle unsigned; macOS identifies it by "
                + "code hash, which changes on EVERY rebuild, so the "
                + "Accessibility grant dies each update\n", stderr)
            return .problem(reason)
        }
        if !identity.hasPrefix("Developer ID Application") {
            fputs("[sign] WARNING: signing with \"\(identity)\" — only a "
                + "Developer ID Application certificate satisfies the pinned "
                + "requirement; this signature is a different client to TCC\n", stderr)
        }
        let result = run("/usr/bin/codesign",
                         "--force", "--sign", identity,
                         "--identifier", identifier,
                         "--timestamp=none", path)
        guard result.status == 0 else {
            fputs("[sign] bundle codesign failed: \(result.output)\n", stderr)
            return .problem("codesign failed")
        }
        fputs("[sign] bundle signed with \"\(identity)\"\n", stderr)
        return verify(bundleAt: path)
    }

    /// Proves the signature we just wrote is the one TCC holds a grant for.
    /// "codesign exited 0" is a WEAKER fact than it looks: it also exits 0
    /// for an Apple Development signature, an expired certificate, and an
    /// ad-hoc one — each of which reads as a brand new client to macOS and
    /// costs the user a trip through System Settings. Under launchd the
    /// private key can be unreachable non-interactively, which is precisely
    /// where a silent skip used to happen.
    @discardableResult
    static func verify(bundleAt path: String) -> SignOutcome {
        for gate in verificationGates(bundleAt: path) {
            let check = run(gate)
            guard check.status == 0 else {
                let detail = check.output.trimmingCharacters(in: .whitespacesAndNewlines)
                fputs("[sign] VERIFICATION FAILED (\(gate.joined(separator: " "))): "
                    + "\(detail)\n", stderr)
                return .problem("signature does not satisfy the pinned requirement")
            }
        }
        fputs("[sign] verified against the pinned requirement — "
            + "the Accessibility grant carries over\n", stderr)
        return .verified
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
        run([launchPath] + args)
    }

    private static func run(_ argv: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (-1, "Failed to launch \(argv[0]): \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
