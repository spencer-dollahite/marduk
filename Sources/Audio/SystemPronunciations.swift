import AVFoundation
import Foundation

/// The user's macOS pronunciation dictionary (System Settings → Accessibility
/// → Read and Speak Content → Pronunciations), imported into Marduk's reads.
///
/// macOS never applies these entries to third-party AVSpeechSynthesizer
/// clients (hardware-verified on macOS 26), but the store is readable: the
/// `com.apple.universalaccess` defaults domain holds `pronunciationsListKey`,
/// an array of NSKeyedArchiver blobs, each archiving one
/// `UAPronunciationSubstitutionModel`. That class is private — a stand-in
/// class registered under the same name decodes the same keys. Text entries
/// (`replacementString`) are substituted into the read before preprocessing;
/// voice-captured entries carry a phonetic transcription in `ipa` and are
/// applied as `AVSpeechSynthesisIPANotationAttribute` ranges at utterance
/// build, leaving the text — and every motion/search offset — untouched.
///
/// UNDOCUMENTED FORMAT: any macOS release may reshape it, so every failure
/// path degrades to "no entries" (Marduk then behaves exactly as it did
/// before this feature) with count-only logging — phrases are user content
/// and never logged.
enum SystemPronunciations {

    struct Entry: Equatable {
        let phrase: String
        /// Spoken respelling for typed entries; empty when the entry is
        /// phonetic-only.
        let replacement: String
        /// IPA transcription for voice-captured entries; nil for typed ones.
        let ipa: String?
        let active: Bool
        let ignoreCase: Bool
        /// "en"-style prefix the reading voice's language must match; nil or
        /// empty = unscoped.
        let language: String?
        let appliesToAllApps: Bool
        let bundleIdentifiers: Set<String>
    }

    private static let domain = "com.apple.universalaccess" as CFString

    // Count-only change log so a stable dictionary doesn't spam every read.
    private nonisolated(unsafe) static var lastLoggedSummary: String?

    /// All decodable, active entries, fresh from cfprefsd. Called at read
    /// start (dozens of entries at most — the cost is trivial), so Settings
    /// edits apply to the very next read with zero plumbing.
    static func fetch() -> [Entry] {
        CFPreferencesAppSynchronize(domain)
        if let enabled = CFPreferencesCopyAppValue("pronunciationsEnabledKey" as CFString,
                                                   domain) as? Bool, !enabled {
            return []
        }
        guard let blobs = CFPreferencesCopyAppValue("pronunciationsListKey" as CFString,
                                                    domain) as? [Data], !blobs.isEmpty else {
            return []
        }
        let decoded = blobs.compactMap(decode)
        let summary = "\(decoded.count) of \(blobs.count)"
        if summary != lastLoggedSummary {
            lastLoggedSummary = summary
            fputs("[speech] system pronunciations: \(summary) entries decoded\n", stderr)
        }
        return decoded.filter(\.active)
    }

    /// One archived model → Entry. Nil (skip, never crash) on any surprise.
    static func decode(_ blob: Data) -> Entry? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: blob) else { return nil }
        unarchiver.requiresSecureCoding = false
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        unarchiver.setClass(ArchivedModel.self,
                            forClassName: "UAPronunciationSubstitutionModel")
        defer { unarchiver.finishDecoding() }
        guard let model = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
                as? ArchivedModel,
              let phrase = model.phrase, !phrase.isEmpty else { return nil }
        let replacement = model.replacement ?? ""
        // An entry with neither a respelling nor phonetics can't change speech
        guard model.ipa != nil || !replacement.isEmpty else { return nil }
        return Entry(phrase: phrase,
                     replacement: replacement,
                     ipa: model.ipa,
                     active: model.active,
                     ignoreCase: model.ignoreCase,
                     language: model.language,
                     appliesToAllApps: model.appliesToAllApps,
                     bundleIdentifiers: model.bundles)
    }

    /// The entries that apply right now: language prefix-matched against the
    /// reading voice ("en" matches "en-US"), app scoping matched against the
    /// frontmost app at read start. Unknown frontmost (inline CLI) keeps
    /// all-apps entries and drops scoped ones.
    static func relevant(_ entries: [Entry], voiceLanguage: String?,
                         frontmostBundleID: String?) -> [Entry] {
        entries.filter { entry in
            if let lang = entry.language, !lang.isEmpty {
                guard let voiceLang = voiceLanguage,
                      voiceLang.lowercased().hasPrefix(lang.lowercased()) else { return false }
            }
            if !entry.appliesToAllApps {
                guard let app = frontmostBundleID,
                      entry.bundleIdentifiers.contains(app) else { return false }
            }
            return true
        }
    }

    /// Whole-word text substitution for typed entries, applied to the raw
    /// read BEFORE preprocessing so motions, search, and spell all see one
    /// consistent text. (Consequence: `z` spells the replacement — same deal
    /// as the verbalizer's rewrites.) IPA entries never touch the text.
    /// ORDER-INDEPENDENT by construction: every match is found against the
    /// ORIGINAL text and applied in one pass, so no entry can rewrite
    /// another's output. Substituting progressively meant a chain (A→B,
    /// B→C) resolved differently depending on the order macOS happened to
    /// store the entries in — the same dictionary could read the document
    /// two different ways.
    ///
    /// Overlaps resolve by LONGEST phrase first, then earliest position —
    /// deterministic regardless of array order, and the intuitive reading
    /// when a specific phrase sits inside a more general one.
    static func applyText(_ entries: [Entry], to text: String) -> String {
        var matches: [(range: NSRange, replacement: String, length: Int)] = []
        for entry in entries where entry.ipa == nil && !entry.replacement.isEmpty {
            for range in wholeWordRanges(of: entry.phrase, in: text,
                                         ignoreCase: entry.ignoreCase) {
                matches.append((range, entry.replacement, entry.phrase.utf16.count))
            }
        }
        guard !matches.isEmpty else { return text }
        matches.sort {
            $0.range.location != $1.range.location
                ? $0.range.location < $1.range.location
                : $0.length > $1.length
        }
        var claimed: [(range: NSRange, replacement: String)] = []
        var consumedUpTo = 0
        for match in matches where match.range.location >= consumedUpTo {
            claimed.append((match.range, match.replacement))
            consumedUpTo = match.range.location + match.range.length
        }
        let mutable = NSMutableString(string: text)
        for claim in claimed.reversed() {
            mutable.replaceCharacters(in: claim.range, with: claim.replacement)
        }
        return mutable as String
    }

    /// IPA application: the processed read text with
    /// AVSpeechSynthesisIPANotationAttribute on every whole-word match.
    /// Nil when nothing matches — callers keep the cheap plain-string
    /// utterance. Re-run per respeak substring, so ranges always fit.
    static func attributed(_ text: String, entries: [Entry]) -> NSAttributedString? {
        var matched = false
        let result = NSMutableAttributedString(string: text)
        let key = NSAttributedString.Key(AVSpeechSynthesisIPANotationAttribute)
        for entry in entries {
            guard let ipa = entry.ipa else { continue }
            for range in wholeWordRanges(of: entry.phrase, in: text,
                                         ignoreCase: entry.ignoreCase) {
                result.addAttribute(key, value: ipa, range: range)
                matched = true
            }
        }
        return matched ? result : nil
    }

    /// UTF-16 ranges of `phrase` in `text` bounded by non-alphanumerics —
    /// "marduk" never fires inside "marduks".
    static func wholeWordRanges(of phrase: String, in text: String,
                                ignoreCase: Bool) -> [NSRange] {
        guard !phrase.isEmpty else { return [] }
        let ns = text as NSString
        let options: NSString.CompareOptions = ignoreCase ? [.caseInsensitive] : []
        var ranges: [NSRange] = []
        var location = 0
        while location < ns.length {
            let found = ns.range(of: phrase, options: options,
                                 range: NSRange(location: location,
                                                length: ns.length - location))
            guard found.location != NSNotFound else { break }
            if !isWordChar(ns, at: found.location - 1),
               !isWordChar(ns, at: found.location + found.length) {
                ranges.append(found)
            }
            location = found.location + max(found.length, 1)
        }
        return ranges
    }

    private static func isWordChar(_ ns: NSString, at index: Int) -> Bool {
        guard index >= 0, index < ns.length else { return false }
        guard let scalar = Unicode.Scalar(ns.character(at: index)) else {
            // Surrogate half (emoji etc.) — treat as a word character so a
            // phrase glued to one doesn't substitute
            return true
        }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    /// Stand-in for the private UAPronunciationSubstitutionModel: decodes
    /// the same archive keys, defaults every missing flag permissively.
    /// The @objc name is arbitrary but must be stable (compiler-enforced
    /// for NSCoding) — decoding maps the archive's class name explicitly.
    @objc(MardukPronunciationArchivedModel)
    private final class ArchivedModel: NSObject, NSCoding {
        let phrase: String?
        let replacement: String?
        let ipa: String?
        let active: Bool
        let ignoreCase: Bool
        let language: String?
        let appliesToAllApps: Bool
        let bundles: Set<String>

        required init?(coder: NSCoder) {
            // Flags are archived as OBJECT REFERENCES (UID → CFBoolean), not
            // inline primitives — decodeBool(forKey:) mismatches there, and
            // with .setErrorAndReturn that first error POISONS every decode
            // after it (fixture-caught: all flags false, later fields nil).
            // decodeObject resolves references and inline values alike, and
            // a failed Swift cast never touches the coder's error state.
            func flag(_ key: String) -> Bool {
                guard coder.containsValue(forKey: key) else { return true }
                return (coder.decodeObject(forKey: key) as? NSNumber)?.boolValue ?? true
            }
            phrase = coder.decodeObject(forKey: "originalString") as? String
            replacement = coder.decodeObject(forKey: "replacementString") as? String
            let attributed = coder.decodeObject(forKey: "ipa") as? NSAttributedString
            let phonetic = attributed?.string
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            ipa = phonetic.isEmpty ? nil : phonetic
            active = flag("active")
            ignoreCase = flag("ignoreCase")
            language = coder.decodeObject(forKey: "language") as? String
            appliesToAllApps = flag("appliesToAllApps")
            let set = coder.decodeObject(forKey: "bundleIdentifiers") as? NSSet
            bundles = Set((set?.allObjects as? [String]) ?? [])
            super.init()
        }

        // Never archived — decode-only stand-in
        func encode(with coder: NSCoder) {}
    }
}
