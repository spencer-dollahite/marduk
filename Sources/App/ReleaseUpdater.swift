import Foundation

/// Downloads, verifies, and installs a notarized release DMG in place —
/// the self-update path for Homebrew and plain-DMG installs (the source
/// channel git-pulls instead). Security model: the DMG comes only from
/// the VERSIONED GitHub release asset URL over HTTPS, and the staged app
/// must pass codesign strict verification, a PINNED designated
/// requirement (our bundle identifier signed by our Developer ID team),
/// and a spctl notarization assessment BEFORE the live bundle is
/// touched. Any failure leaves the current install exactly as it was.
/// All logs `[update]`.
enum ReleaseUpdater {

    enum Failure: Error, Equatable {
        case download, mount, verification, install

        /// User-speakable summary; details are in the log.
        var spoken: String {
            switch self {
            case .download: return "The update could not be downloaded. Is the network up?"
            case .mount: return "The update download could not be opened."
            case .verification: return "The update could not be verified and was not installed."
            case .install: return "The update could not be installed."
            }
        }
    }

    static let repoSlug = "spencer-dollahite/marduk"

    /// Pinned designated requirement: OUR bundle identifier, signed with
    /// a Developer ID certificate belonging to OUR team. A perfectly
    /// valid signature from anyone else fails this.
    static let requirement = "=identifier \"com.marduk.daemon\" and anchor apple generic "
        + "and certificate leaf[subject.OU] = X56UYJ5NDJ"

    /// The asset URL for a tag. VERSIONED, never the floating `latest`
    /// link — the swap must install exactly the tag that was checked and
    /// announced, and `latest` could move between the two.
    ///
    /// Pure and separate so it can be pinned: this is the one input an
    /// attacker-influenced release feed controls, and a tag carrying `..`
    /// or `/` must not be able to walk the path somewhere else.
    static func assetURL(tag: String) -> String? {
        // A release tag is three integers; anything else is refused rather
        // than interpolated. Also rejects a `v` prefix arriving twice,
        // which would silently 404.
        guard ReleaseCheck.components(tag) != nil, !tag.hasPrefix("v") else {
            return nil
        }
        return "https://github.com/\(repoSlug)/releases/download/v\(tag)/Marduk.dmg"
    }

    /// The three gates the STAGED copy must pass before anything is
    /// swapped. A table so a test can assert none of them silently
    /// disappears in a refactor — nothing else in the repo would notice.
    static func verificationGates(staging: String) -> [[String]] {
        [
            ["/usr/bin/codesign", "--verify", "--strict", "--deep", staging],
            ["/usr/bin/codesign", "--verify", "-R=" + requirement, staging],
            ["/usr/sbin/spctl", "--assess", "--type", "execute", staging],
        ]
    }

    /// Full pipeline: download v<tag>'s DMG → mount → stage → verify →
    /// atomic swap at `liveBundlePath` (the Bundler aside-then-in idiom;
    /// a running daemon keeps its inode). Returns the installed bundle's
    /// executable path. Synchronous — call from a background queue.
    static func install(tag: String, liveBundlePath: String) -> Result<String, Failure> {
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory() + "marduk-update-" + UUID().uuidString
        let dmg = tmp + "/Marduk.dmg"
        let mnt = tmp + "/mnt"
        let staging = tmp + "/Marduk.app"
        defer { try? fm.removeItem(atPath: tmp) }
        do {
            try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        } catch {
            fputs("[update] temp dir failed: \(error.localizedDescription)\n", stderr)
            return .failure(.download)
        }

        // Versioned asset URL, never the floating latest link — the swap
        // must install exactly the tag that was checked and announced.
        guard let url = assetURL(tag: tag) else {
            fputs("[update] refusing to build an asset URL for tag \(tag)\n", stderr)
            return .failure(.download)
        }
        fputs("[update] Downloading \(url)\n", stderr)
        let dl = run("/usr/bin/curl", "-fsSL", "-m", "300", "-o", dmg, url)
        guard dl.status == 0, fm.fileExists(atPath: dmg) else {
            fputs("[update] download failed (\(dl.status)): \(dl.output)\n", stderr)
            return .failure(.download)
        }

        let attach = run("/usr/bin/hdiutil", "attach", dmg,
                         "-nobrowse", "-readonly", "-mountpoint", mnt)
        guard attach.status == 0 else {
            fputs("[update] hdiutil attach failed: \(attach.output)\n", stderr)
            return .failure(.mount)
        }
        var detached = false
        defer { if !detached { _ = run("/usr/bin/hdiutil", "detach", mnt, "-force") } }

        // ditto preserves signatures, resource forks, and xattrs — cp -R
        // can subtly break a sealed bundle
        let copy = run("/usr/bin/ditto", mnt + "/Marduk.app", staging)
        let det = run("/usr/bin/hdiutil", "detach", mnt)
        detached = det.status == 0
        guard copy.status == 0 else {
            fputs("[update] staging copy failed: \(copy.output)\n", stderr)
            return .failure(.mount)
        }

        // Verify the STAGED copy — all three gates, before any swap
        for gate in verificationGates(staging: staging) {
            let check = run(gate)
            guard check.status == 0 else {
                fputs("[update] VERIFICATION FAILED (\(gate[0]) \(gate[1])): "
                    + "\(check.output)\n", stderr)
                return .failure(.verification)
            }
        }
        fputs("[update] \(tag) verified: signature, pinned requirement, notarization\n", stderr)

        // Atomic swap: aside, in, drop the aside. Roll back on failure.
        let old = liveBundlePath + ".old"
        try? fm.removeItem(atPath: old)
        do {
            if fm.fileExists(atPath: liveBundlePath) {
                try fm.moveItem(atPath: liveBundlePath, toPath: old)
            }
            try fm.moveItem(atPath: staging, toPath: liveBundlePath)
        } catch {
            fputs("[update] install failed: \(error.localizedDescription) — rolling back\n", stderr)
            if !fm.fileExists(atPath: liveBundlePath), fm.fileExists(atPath: old) {
                try? fm.moveItem(atPath: old, toPath: liveBundlePath)
            }
            return .failure(.install)
        }
        try? fm.removeItem(atPath: old)
        fputs("[update] installed \(tag) at \(liveBundlePath)\n", stderr)
        return .success(liveBundlePath + "/Contents/MacOS/marduk")
    }

    // MARK: - Process plumbing (mirrors Bundler.run)

    private static func run(_ argv: String...) -> (status: Int32, output: String) {
        run(argv)
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
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
