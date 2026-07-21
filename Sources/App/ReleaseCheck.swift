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
}
