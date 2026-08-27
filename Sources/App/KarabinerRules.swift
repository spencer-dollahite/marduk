import Foundation

/// The user's OWN Karabiner rules, carried into karabiner.json by the
/// same rewrite that installs Marduk's read button and panic chord.
///
/// Marduk already owns `~/.config/karabiner/karabiner.json` — it backs up
/// before every write, refuses to write on a parse failure, and strips
/// only rules it recognises by description. That machinery is exactly
/// what a user needs to keep personal rules versioned somewhere and
/// applied to a Mac without hand-copying a config file, so this extends
/// it rather than adding a second writer to the same file.
///
/// Rules live OUTSIDE this repo (`~/.config/marduk/ke/rules.json`,
/// typically a clone of a PRIVATE repo — the marduk-news pattern). A
/// personal Karabiner config is personal data: app lists, home-directory
/// paths, device IDs. Shipping one inside a public repo and copying it
/// over a stranger's live config would wipe their setup and hand them
/// someone else's, so the source is user-local and EMPTY BY DEFAULT.
/// Absent file = no rules = the pre-existing behaviour exactly.
///
/// Pure: every function here is parse-and-merge over dictionaries, so
/// the whole contract is testable without a Karabiner install (which CI
/// can never have — DriverKit approval is interactive).
enum KarabinerRules {

    /// Injected rules are TAGGED in their description, which is what makes
    /// the merge idempotent and reversible: the rewrite strips every rule
    /// carrying this prefix before re-inserting the current set, so a rule
    /// DELETED from rules.json disappears from karabiner.json too. Without
    /// a tag we could add rules but never find them again to remove them.
    /// Same shape as the existing "Marduk read button" / "Marduk panic
    /// chord" prefixes the rewrite already strips.
    static let tagPrefix = "Marduk user — "

    /// Which profile a rule is carried into. The user asked for this PER
    /// RULE: some bindings should exist only while Marduk is driving the
    /// keyboard, some should survive with Marduk stopped, some both.
    ///
    /// `.user` is the one place Marduk writes into a profile it does not
    /// own, so it stays narrow by construction — only TAGGED rules are
    /// ever added or removed there, everything else in that profile is
    /// left byte-identical.
    enum Target: String {
        case marduk
        case user
    }

    struct Entry {
        let targets: Set<Target>
        /// The Karabiner rule object, description already tagged.
        let rule: [String: Any]
        /// The user's own description, untagged. Counts only in logs —
        /// a rule description is user content (see the privacy rule).
        let description: String
    }

    /// Parse the rules file. DEFENSIVE like every other user-supplied
    /// store here (pronunciations, the newsboat cache): a malformed entry
    /// is DROPPED, never thrown, because the alternative is a daemon that
    /// won't hand the keyboard back over a stray comma. An unusable file
    /// yields zero rules, which is the same as no file at all.
    ///
    /// Accepts either `{"rules": [...]}` or a bare `[...]`, since both are
    /// the obvious thing to write by hand.
    static func parse(_ data: Data) -> [Entry] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        let raw: [[String: Any]]
        if let array = json as? [[String: Any]] {
            raw = array
        } else if let object = json as? [String: Any],
                  let array = object["rules"] as? [[String: Any]] {
            raw = array
        } else {
            return []
        }
        return raw.compactMap(entry(from:))
    }

    static func entry(from item: [String: Any]) -> Entry? {
        // The rule may be nested under "rule" (so "profiles" can sit
        // beside it without polluting the object Karabiner reads) or the
        // item may BE the rule, with "profiles" alongside — accept both
        // and strip our key on the way out.
        var rule = (item["rule"] as? [String: Any]) ?? item
        rule.removeValue(forKey: "profiles")
        guard let description = rule["description"] as? String,
              !description.trimmingCharacters(in: .whitespaces).isEmpty,
              let manipulators = rule["manipulators"] as? [[String: Any]],
              !manipulators.isEmpty else { return nil }
        // Re-tagging an already-tagged description would compound the
        // prefix on every round trip through an exported config.
        let bare = description.hasPrefix(tagPrefix)
            ? String(description.dropFirst(tagPrefix.count))
            : description
        rule["description"] = tagPrefix + bare
        return Entry(targets: targets(from: item), rule: rule,
                     description: bare)
    }

    /// Missing, empty, or wholly unrecognised `profiles` means `.marduk`
    /// — the SAFE default, since that profile is Marduk's own and a rule
    /// landing there can never damage a config Marduk doesn't manage.
    static func targets(from item: [String: Any]) -> Set<Target> {
        guard let names = item["profiles"] as? [String] else { return [.marduk] }
        let parsed = Set(names.compactMap {
            Target(rawValue: $0.lowercased().trimmingCharacters(in: .whitespaces))
        })
        return parsed.isEmpty ? [.marduk] : parsed
    }

    /// Remove every previously-injected rule. Idempotence lives here: the
    /// rewrite strips, then re-inserts, so applying twice is applying once
    /// and a rule dropped from the file is dropped from the config.
    static func strip(_ rules: [[String: Any]]) -> [[String: Any]] {
        rules.filter {
            !(($0["description"] as? String) ?? "").hasPrefix(tagPrefix)
        }
    }

    /// Strip, then insert the entries bound for `target` at the top.
    static func merge(into rules: [[String: Any]], entries: [Entry],
                      target: Target) -> [[String: Any]] {
        var merged = strip(rules)
        let wanted = entries.filter { $0.targets.contains(target) }
        merged.insert(contentsOf: wanted.map(\.rule), at: 0)
        return merged
    }
}
