import AVFoundation
import XCTest
@testable import marduk

/// The fixtures are byte-faithful reconstructions of the archives macOS 26
/// writes to com.apple.universalaccess/pronunciationsListKey (structure
/// captured from a real user entry via plistlib): NSKeyedArchiver blobs of
/// the private UAPronunciationSubstitutionModel. If Apple reshapes the
/// format, decode() must degrade to nil — never crash.
final class SystemPronunciationsTests: XCTestCase {

    // phrase "marduk" → replacement "banana", empty ipa, language "en",
    // active/ignoreCase/appliesToAllApps all true
    private static let textEntry = Data(base64Encoded: "YnBsaXN0MDDUAQIDBAUGQkVZJGFyY2hpdmVyWCRvYmplY3RzVCR0b3BYJHZlcnNpb25fEA9OU0tleWVkQXJjaGl2ZXKvEA8HCBsfJSYnKCwwMzc7Pj9VJG51bGzaCQoLDA0ODxAREhMUFBUUFhcYGRpWJGNsYXNzVmFjdGl2ZV8QEGFwcGxpZXNUb0FsbEFwcHNfEBFidW5kbGVJZGVudGlmaWVyc1ppZ25vcmVDYXNlU2lwYVhsYW5ndWFnZV5vcmlnaW5hbFN0cmluZ18QEXJlcGxhY2VtZW50U3RyaW5nVHV1aWSADoAEgAuAB4ANgAWABoAC0gkcHR5cTlMudXVpZGJ5dGVzgANPEBD+nDcZgqdN0au70m8sQzWd0iAhIiNYJGNsYXNzZXNaJGNsYXNzbmFtZaIjJFZOU1VVSURYTlNPYmplY3QJVm1hcmR1a1ZiYW5hbmHSCSkqK1hOU1N0cmluZ4AKgAjSCS0uL1lOUy5zdHJpbmeACVDSICExMqMyKSRfEA9OU011dGFibGVTdHJpbmfSICE0NaM1NiRfEBlOU011dGFibGVBdHRyaWJ1dGVkU3RyaW5nXxASTlNBdHRyaWJ1dGVkU3RyaW5n0gk4OTpaTlMub2JqZWN0c4AMoNIgITw9oj0kVU5TU2V0UmVu0iAhQEGiQSRfECBVQVByb251bmNpYXRpb25TdWJzdGl0dXRpb25Nb2RlbNFDRFRyb290gAESAAGGoAAIABEAGwAkACkAMgBEAFYAXABxAHgAfwCSAKYAsQC1AL4AzQDhAOYA6ADqAOwA7gDwAPIA9AD2APsBCAEKAR0BIgErATYBOQFAAUkBSgFRAVgBXQFmAWgBagFvAXkBewF8AYEBhQGXAZwBoAG8AdEB1gHhAeMB5AHpAewB8gH1AfoB/QIgAiMCKAIqAAAAAAAAAgEAAAAAAAAARgAAAAAAAAAAAAAAAAAAAi8=")!

    // phrase "gif" → empty replacement, ipa "ˈdʒɪf" (a voice-captured entry)
    private static let ipaEntry = Data(base64Encoded: "YnBsaXN0MDDUAQIDBAUGQkVZJGFyY2hpdmVyWCRvYmplY3RzVCR0b3BYJHZlcnNpb25fEA9OU0tleWVkQXJjaGl2ZXKvEA8HCBsfJSYnKCwwMzc7Pj9VJG51bGzaCQoLDA0ODxAREhMUFBUUFhcYGRpWJGNsYXNzVmFjdGl2ZV8QEGFwcGxpZXNUb0FsbEFwcHNfEBFidW5kbGVJZGVudGlmaWVyc1ppZ25vcmVDYXNlU2lwYVhsYW5ndWFnZV5vcmlnaW5hbFN0cmluZ18QEXJlcGxhY2VtZW50U3RyaW5nVHV1aWSADoAEgAuAB4ANgAWABoAC0gkcHR5cTlMudXVpZGJ5dGVzgANPEBD+nDcZgqdN0au70m8sQzWd0iAhIiNYJGNsYXNzZXNaJGNsYXNzbmFtZaIjJFZOU1VVSURYTlNPYmplY3QJU2dpZlDSCSkqK1hOU1N0cmluZ4AKgAjSCS0uL1lOUy5zdHJpbmeACWUCyABkApICagBm0iAhMTKjMikkXxAPTlNNdXRhYmxlU3RyaW5n0iAhNDWjNTYkXxAZTlNNdXRhYmxlQXR0cmlidXRlZFN0cmluZ18QEk5TQXR0cmlidXRlZFN0cmluZ9IJODk6Wk5TLm9iamVjdHOADKDSICE8PaI9JFVOU1NldFJlbtIgIUBBokEkXxAgVUFQcm9udW5jaWF0aW9uU3Vic3RpdHV0aW9uTW9kZWzRQ0RUcm9vdIABEgABhqAACAARABsAJAApADIARABWAFwAcQB4AH8AkgCmALEAtQC+AM0A4QDmAOgA6gDsAO4A8ADyAPQA9gD7AQgBCgEdASIBKwE2ATkBQAFJAUoBTgFPAVQBXQFfAWEBZgFwAXIBfQGCAYYBmAGdAaEBvQHSAdcB4gHkAeUB6gHtAfMB9gH7Af4CIQIkAikCKwAAAAAAAAIBAAAAAAAAAEYAAAAAAAAAAAAAAAAAAAIw")!

    // phrase "vim" → "vim editor", appliesToAllApps false,
    // bundleIdentifiers {com.apple.Terminal}
    private static let scopedEntry = Data(base64Encoded: "YnBsaXN0MDDUAQIDBAUGRklZJGFyY2hpdmVyWCRvYmplY3RzVCR0b3BYJHZlcnNpb25fEA9OU0tleWVkQXJjaGl2ZXKvEBEHCBwgJicoKS0xNDg9QEFCRVUkbnVsbNoJCgsMDQ4PEBESExQVFhQXGBkaG1YkY2xhc3NWYWN0aXZlXxAQYXBwbGllc1RvQWxsQXBwc18QEWJ1bmRsZUlkZW50aWZpZXJzWmlnbm9yZUNhc2VTaXBhWGxhbmd1YWdlXm9yaWdpbmFsU3RyaW5nXxARcmVwbGFjZW1lbnRTdHJpbmdUdXVpZIAPgASAEIALgAeADoAFgAaAAtIJHR4fXE5TLnV1aWRieXRlc4ADTxAQ/pw3GYKnTdGru9JvLEM1ndIhIiMkWCRjbGFzc2VzWiRjbGFzc25hbWWiJCVWTlNVVUlEWE5TT2JqZWN0CVN2aW1admltIGVkaXRvctIJKissWE5TU3RyaW5ngAqACNIJLi8wWU5TLnN0cmluZ4AJUNIhIjIzozMqJV8QD05TTXV0YWJsZVN0cmluZ9IhIjU2ozY3JV8QGU5TTXV0YWJsZUF0dHJpYnV0ZWRTdHJpbmdfEBJOU0F0dHJpYnV0ZWRTdHJpbmfSCTk6O1pOUy5vYmplY3RzgAyhPIAN0iEiPj+iPyVVTlNTZXRfEBJjb20uYXBwbGUuVGVybWluYWxSZW7SISJDRKJEJV8QIFVBUHJvbnVuY2lhdGlvblN1YnN0aXR1dGlvbk1vZGVsCNFHSFRyb290gAESAAGGoAAIABEAGwAkACkAMgBEAFgAXgBzAHoAgQCUAKgAswC3AMAAzwDjAOgA6gDsAO4A8ADyAPQA9gD4APoA/wEMAQ4BIQEmAS8BOgE9AUQBTQFOAVIBXQFiAWsBbQFvAXQBfgGAAYEBhgGKAZwBoQGlAcEB1gHbAeYB6AHqAewB8QH0AfoCDwISAhcCGgI9Aj4CQQJGAkgAAAAAAAACAQAAAAAAAABKAAAAAAAAAAAAAAAAAAACTQ==")!

    // MARK: - Decoding

    func testDecodesTextEntry() {
        let entry = SystemPronunciations.decode(Self.textEntry)
        XCTAssertEqual(entry?.phrase, "marduk")
        XCTAssertEqual(entry?.replacement, "banana")
        XCTAssertNil(entry?.ipa)
        XCTAssertEqual(entry?.language, "en")
        XCTAssertEqual(entry?.active, true)
        XCTAssertEqual(entry?.ignoreCase, true)
        XCTAssertEqual(entry?.appliesToAllApps, true)
        XCTAssertEqual(entry?.bundleIdentifiers, [])
    }

    func testDecodesVoiceCapturedIPAEntry() {
        let entry = SystemPronunciations.decode(Self.ipaEntry)
        XCTAssertEqual(entry?.phrase, "gif")
        XCTAssertEqual(entry?.ipa, "ˈdʒɪf")
        XCTAssertEqual(entry?.replacement, "")
    }

    func testDecodesAppScopedEntry() {
        let entry = SystemPronunciations.decode(Self.scopedEntry)
        XCTAssertEqual(entry?.phrase, "vim")
        XCTAssertEqual(entry?.appliesToAllApps, false)
        XCTAssertEqual(entry?.bundleIdentifiers, ["com.apple.Terminal"])
    }

    func testGarbageBlobDecodesToNilNotCrash() {
        XCTAssertNil(SystemPronunciations.decode(Data([0x00, 0x01, 0x02])))
        XCTAssertNil(SystemPronunciations.decode(Data()))
        // Valid plist, wrong shape
        let plist = try! PropertyListSerialization.data(
            fromPropertyList: ["not": "an archive"], format: .binary, options: 0)
        XCTAssertNil(SystemPronunciations.decode(plist))
    }

    // MARK: - Relevance filtering

    private func entry(phrase: String, replacement: String = "x", ipa: String? = nil,
                       ignoreCase: Bool = true, language: String? = "en",
                       allApps: Bool = true, bundles: Set<String> = []) -> SystemPronunciations.Entry {
        .init(phrase: phrase, replacement: replacement, ipa: ipa, active: true,
              ignoreCase: ignoreCase, language: language,
              appliesToAllApps: allApps, bundleIdentifiers: bundles)
    }

    func testLanguageScopePrefixMatchesVoice() {
        let en = entry(phrase: "a")
        XCTAssertEqual(SystemPronunciations.relevant([en], voiceLanguage: "en-US",
                                                     frontmostBundleID: nil).count, 1)
        XCTAssertEqual(SystemPronunciations.relevant([en], voiceLanguage: "fr-FR",
                                                     frontmostBundleID: nil).count, 0)
        let unscoped = entry(phrase: "a", language: nil)
        XCTAssertEqual(SystemPronunciations.relevant([unscoped], voiceLanguage: "fr-FR",
                                                     frontmostBundleID: nil).count, 1)
    }

    func testAppScopeMatchesFrontmost() {
        let scoped = entry(phrase: "a", allApps: false, bundles: ["com.apple.Terminal"])
        XCTAssertEqual(SystemPronunciations.relevant(
            [scoped], voiceLanguage: "en-US",
            frontmostBundleID: "com.apple.Terminal").count, 1)
        XCTAssertEqual(SystemPronunciations.relevant(
            [scoped], voiceLanguage: "en-US",
            frontmostBundleID: "org.mozilla.firefox").count, 0)
        // Unknown frontmost (inline CLI) drops scoped entries
        XCTAssertEqual(SystemPronunciations.relevant(
            [scoped], voiceLanguage: "en-US", frontmostBundleID: nil).count, 0)
    }

    // MARK: - Text substitution

    func testWholeWordSubstitution() {
        let e = [entry(phrase: "marduk", replacement: "banana")]
        XCTAssertEqual(SystemPronunciations.applyText(e, to: "run marduk now"),
                       "run banana now")
        // Word boundaries: no fire inside larger words
        XCTAssertEqual(SystemPronunciations.applyText(e, to: "marduks and remarduk"),
                       "marduks and remarduk")
        // Punctuation is a boundary; multiple occurrences all replace
        XCTAssertEqual(SystemPronunciations.applyText(e, to: "marduk, marduk!"),
                       "banana, banana!")
    }

    func testCaseSensitivityHonorsIgnoreCase() {
        let insensitive = [entry(phrase: "marduk", replacement: "banana")]
        XCTAssertEqual(SystemPronunciations.applyText(insensitive, to: "Marduk MARDUK"),
                       "banana banana")
        let sensitive = [entry(phrase: "marduk", replacement: "banana", ignoreCase: false)]
        XCTAssertEqual(SystemPronunciations.applyText(sensitive, to: "Marduk marduk"),
                       "Marduk banana")
    }

    func testIPAEntriesNeverMutateText() {
        let e = [entry(phrase: "gif", replacement: "", ipa: "ˈdʒɪf")]
        XCTAssertEqual(SystemPronunciations.applyText(e, to: "a gif file"), "a gif file")
    }

    // MARK: - IPA attribution

    func testAttributedMarksWholeWordMatches() {
        let e = [entry(phrase: "gif", replacement: "", ipa: "ˈdʒɪf")]
        let attributed = SystemPronunciations.attributed("the gif, a gift", entries: e)
        XCTAssertNotNil(attributed)
        XCTAssertEqual(attributed?.string, "the gif, a gift")
        let key = NSAttributedString.Key(AVSpeechSynthesisIPANotationAttribute)
        XCTAssertEqual(attributed?.attribute(key, at: 4, effectiveRange: nil) as? String,
                       "ˈdʒɪf")
        // "gift" is not a match
        XCTAssertNil(attributed?.attribute(key, at: 11, effectiveRange: nil))
    }

    func testAttributedNilWhenNothingMatches() {
        let e = [entry(phrase: "gif", replacement: "", ipa: "ˈdʒɪf")]
        XCTAssertNil(SystemPronunciations.attributed("no match here", entries: e))
        XCTAssertNil(SystemPronunciations.attributed("anything", entries: []))
    }
}
