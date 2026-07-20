import Foundation

/// Latest-release lookup support for non-source installs (Homebrew or a
/// downloaded DMG can't git-pull). The pure parsing lives here so it's
/// unit-testable; the network call stays with the other curl shells in
/// DaemonServer.
enum ReleaseCheck {
    /// GitHub /releases/latest JSON → bare version ("v0.3.2" → "0.3.2").
    static func parseLatestTag(_ json: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(
                  with: Data(json.utf8)) as? [String: Any],
              let tag = obj["tag_name"] as? String, !tag.isEmpty else { return nil }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }
}
