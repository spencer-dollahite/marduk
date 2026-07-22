import Foundation

/// Latest-release lookup support for non-source installs (Homebrew or a
/// downloaded DMG can't git-pull). The pure parsing lives here so it's
/// unit-testable; the network call stays with the other curl shells in
/// DaemonServer.
enum ReleaseCheck {
    struct LatestRelease: Equatable {
        let tag: String      // bare version, "0.3.6"
        let notes: [String]  // commit subjects from the release body
    }

    /// GitHub /releases/latest JSON → tag + speakable release notes.
    /// release.sh writes the body as "- subject" lines followed by a
    /// "---" install footer — collect the subjects, stop at the rule.
    static func parseLatestRelease(_ json: String) -> LatestRelease? {
        guard let obj = try? JSONSerialization.jsonObject(
                  with: Data(json.utf8)) as? [String: Any],
              let tag = obj["tag_name"] as? String, !tag.isEmpty else { return nil }
        var notes: [String] = []
        for rawLine in (obj["body"] as? String ?? "").split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("---") { break }
            if line.hasPrefix("- ") { notes.append(String(line.dropFirst(2))) }
        }
        return LatestRelease(
            tag: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
            notes: notes
        )
    }

    /// GitHub /releases/latest JSON → bare version ("v0.3.2" → "0.3.2").
    static func parseLatestTag(_ json: String) -> String? {
        parseLatestRelease(json)?.tag
    }

    /// The next PATCH version after a semver string — the only bump the
    /// dd release gesture is allowed to make ("0.4.9" → "0.4.10"; minor
    /// and major bumps are a human judgment and stay with the manual
    /// release.sh). Accepts a leading "v" (tag input). Nil on anything
    /// that isn't three dot-separated integers.
    static func nextPatch(after version: String) -> String? {
        let bare = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let parts = bare.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]), major >= 0,
              let minor = Int(parts[1]), minor >= 0,
              let patch = Int(parts[2]), patch >= 0 else { return nil }
        return "\(major).\(minor).\(patch + 1)"
    }

    /// release.sh narrates its stages as "==> Stage name" lines — the
    /// speakable stage, or nil for ordinary tool output.
    static func stageLine(_ line: String) -> String? {
        guard line.hasPrefix("==> ") else { return nil }
        let stage = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
        return stage.isEmpty ? nil : stage
    }
}
