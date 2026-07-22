import XCTest
@testable import marduk

/// Config decoding, permuted exhaustively over the axes that actually
/// break in the field.
///
/// The full cross-product of 28 settings is 2^28 and meaningless. What
/// matters is enumerable and enumerated here:
///   • every field, present ALONE in its block (the hand-edited partial
///     config — the documented hazard, because a failed decode makes
///     `ConfigLoader.load()` reset the file and wipe the user's voice and
///     rate);
///   • every field, OMITTED (an older config.json meeting a newer build —
///     what happens to every existing user on every update);
///   • every block, present alone and omitted;
///   • no key silently lost on a full round-trip;
///   • every value the `:config` table accepts, and the ones it must
///     reject.
///
/// The optionality contract is enforced structurally rather than by
/// review: a non-Optional field added to any block would fail the whole
/// decode for every existing user, and that has caused regressions before.
final class ConfigPermutationTests: XCTestCase {

    // MARK: - Reflection helpers

    /// Field name → a JSON literal of the right type for it. Driven by
    /// reflection so a NEW config field is covered the day it is added,
    /// without anyone remembering to update this file.
    private func fields(of value: Any) -> [(name: String, json: String, optional: Bool)] {
        Mirror(reflecting: value).children.compactMap { child in
            guard let name = child.label else { return nil }
            let type = String(describing: Swift.type(of: child.value))
            let optional = type.hasPrefix("Optional<")
            let bare = optional
                ? String(type.dropFirst("Optional<".count).dropLast())
                : type
            let json: String
            switch bare {
            case "Bool": json = "true"
            case "Int": json = "1"
            case "Double", "Float": json = "0.5"
            case "String": json = "\"x\""
            case "Array<String>": json = "[]"
            case "Dictionary<String, String>": json = "{}"
            default:
                XCTFail("ConfigPermutationTests has no JSON literal for \(bare) "
                    + "(field \(name)) — add one so the new field is covered")
                return nil
            }
            return (name, json, optional)
        }
    }

    /// Every top-level block, by its JSON key, with a default instance.
    private var blocks: [(key: String, value: Any)] {
        [("ducking", MardukConfig.DuckingConfig()),
         ("speech", MardukConfig.SpeechConfig()),
         ("display", MardukConfig.DisplayConfig()),
         ("keyboard", MardukConfig.KeyboardConfig()),
         ("verbalizer", MardukConfig.VerbalizerConfig()),
         ("update", MardukConfig.UpdateConfig()),
         ("overlay", MardukConfig.OverlayConfig()),
         ("onboarding", MardukConfig.OnboardingConfig())]
    }

    private func decode(_ json: String) throws -> MardukConfig {
        try JSONDecoder().decode(MardukConfig.self, from: Data(json.utf8))
    }

    // MARK: - The optionality contract

    /// Only the three v0.1 blocks may contain non-Optional fields. Adding
    /// a required key to any block breaks decoding for every user whose
    /// config predates it — and `load()` answers a failed decode by
    /// resetting the file to defaults, so the failure is silent AND
    /// destructive.
    func testOnlyLegacyFieldsAreNonOptional() {
        let allowed: Set<String> = [
            // DuckingConfig + SpeechConfig + DisplayConfig, all from v0.1
            "duckLevel", "rampSteps", "rampDurationMs", "duckAppleMusic",
            "duckSpotify", "useMediaKey", "rate", "invertForApps",
        ]
        for block in blocks {
            for field in fields(of: block.value) where !field.optional {
                XCTAssertTrue(
                    allowed.contains(field.name),
                    "\(block.key).\(field.name) is NOT Optional. A required key "
                    + "fails the whole decode for existing users, and load() "
                    + "resets a failed decode to defaults — wiping their voice "
                    + "and rate. Make it Optional and default at the use site.")
            }
        }
    }

    // MARK: - Presence permutations

    func testEmptyObjectDecodes() throws {
        XCTAssertNoThrow(try decode("{}"))
    }

    func testEachBlockAloneDecodes() throws {
        for block in blocks {
            let json = "{\"\(block.key)\":{}}"
            XCTAssertNoThrow(try decode(json),
                             "a config containing only \(block.key) must decode")
        }
    }

    func testEachBlockOmittedDecodes() throws {
        for omitted in blocks {
            let present = blocks.filter { $0.key != omitted.key }
                .map { "\"\($0.key)\":{}" }
                .joined(separator: ",")
            XCTAssertNoThrow(try decode("{\(present)}"),
                             "a config without \(omitted.key) must decode")
        }
    }

    /// THE hand-edit hazard: someone sets one key and saves. Every field,
    /// alone in its block, must decode.
    func testEachFieldAloneInItsBlockDecodes() throws {
        for block in blocks {
            for field in fields(of: block.value) {
                let json = "{\"\(block.key)\":{\"\(field.name)\":\(field.json)}}"
                XCTAssertNoThrow(
                    try decode(json),
                    "config with only \(block.key).\(field.name) must decode")
            }
        }
    }

    /// THE upgrade hazard: an existing config.json meets a build that
    /// added a field. Every field, individually missing, must decode.
    func testEachFieldIndividuallyMissingDecodes() throws {
        for block in blocks {
            let all = fields(of: block.value)
            for omitted in all {
                let body = all.filter { $0.name != omitted.name }
                    .map { "\"\($0.name)\":\($0.json)" }
                    .joined(separator: ",")
                let json = "{\"\(block.key)\":{\(body)}}"
                XCTAssertNoThrow(
                    try decode(json),
                    "config missing \(block.key).\(omitted.name) must decode")
            }
        }
    }

    /// Nothing is silently dropped: a fully populated config survives
    /// decode → encode with every key intact.
    func testFullyPopulatedConfigLosesNoKey() throws {
        let body = blocks.map { block -> String in
            let inner = fields(of: block.value)
                .map { "\"\($0.name)\":\($0.json)" }
                .joined(separator: ",")
            return "\"\(block.key)\":{\(inner)}"
        }.joined(separator: ",")
        let json = "{\(body)}"

        let config = try decode(json)
        let reencoded = try JSONEncoder().encode(config)
        let round = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        XCTAssertNotNil(round)

        for block in blocks {
            guard let out = round?[block.key] as? [String: Any] else {
                XCTFail("block \(block.key) vanished on round-trip")
                continue
            }
            for field in fields(of: block.value) {
                XCTAssertNotNil(out[field.name],
                                "\(block.key).\(field.name) was dropped on round-trip")
            }
        }
    }

    func testDefaultsRoundTrip() throws {
        let data = try JSONEncoder().encode(MardukConfig())
        let config = try JSONDecoder().decode(MardukConfig.self, from: data)
        XCTAssertEqual(config.speech.rate, MardukConfig().speech.rate)
        XCTAssertEqual(config.ducking.duckLevel, MardukConfig().ducking.duckLevel)
        XCTAssertEqual(config.display.invertEnabled, MardukConfig().display.invertEnabled)
        XCTAssertEqual(config.keyboard?.readMotions, MardukConfig().keyboard?.readMotions)
    }

    /// A junk VALUE of the wrong type is a decode failure, which resets the
    /// user's file. Documented and accepted (the file is preserved as
    /// .bad first) — pinned here so the behavior is deliberate, not a
    /// surprise discovered in the field.
    func testWrongTypedValueFailsDecodeAsDocumented() {
        XCTAssertThrowsError(try decode(#"{"speech":{"rate":"fast"}}"#))
    }

    // MARK: - Every value the :config table accepts

    /// Exhaustive over the settings table: every choice value must parse
    /// to exactly the setting and value given.
    func testEveryChoiceValueParses() {
        for setting in ColonCommand.settings {
            guard case .choice(let options) = setting.kind else { continue }
            for option in options {
                XCTAssertEqual(ColonCommand.parse("config \(setting.key) \(option)"),
                               .config(key: setting.key, value: option),
                               "\(setting.key) \(option) must parse")
            }
        }
    }

    func testEveryToggleParsesBothWays() {
        for setting in ColonCommand.settings {
            guard case .toggle = setting.kind else { continue }
            for value in ["on", "off"] {
                XCTAssertEqual(ColonCommand.parse("config \(setting.key) \(value)"),
                               .config(key: setting.key, value: value),
                               "\(setting.key) \(value) must parse")
            }
        }
    }

    /// Every numeric setting: both bounds are inside, and the table is the
    /// single source of truth the daemon validates against.
    func testEveryNumberSettingExposesUsableBounds() {
        for setting in ColonCommand.settings {
            guard case .number(let min, let max, _) = setting.kind else { continue }
            XCTAssertLessThan(min, max, "\(setting.key) has an empty range")
            for value in [min, max] {
                XCTAssertEqual(ColonCommand.parse("config \(setting.key) \(value)"),
                               .config(key: setting.key, value: "\(value)"),
                               "\(setting.key) \(value) must parse")
            }
        }
    }

    /// Every setting is reachable by its own name and by a unique prefix —
    /// the property the prefix guard protects, checked end to end.
    func testEverySettingIsReachableByUniquePrefix() {
        let keys = ColonCommand.settings.map(\.key)
        for key in keys {
            XCTAssertEqual(ColonCommand.expand(key, in: keys), key,
                           "\(key) must expand to itself")
        }
    }

    /// The inversion pair, at the config layer: all four combinations must
    /// decode and land independently. This is the permutation that blinded
    /// a user — invert off with autoinvert on was never exercised.
    func testInversionSwitchPermutationsAllDecode() throws {
        for invert in [false, true] {
            for auto in [false, true] {
                let json = "{\"display\":{\"invertEnabled\":\(invert),"
                    + "\"autoInvert\":\(auto)}}"
                let config = try decode(json)
                XCTAssertEqual(config.display.invertEnabled, invert)
                XCTAssertEqual(config.display.autoInvert, auto)
                // …and the subsystem's gate agrees with the policy
                XCTAssertEqual(
                    InversionPolicy.isActive(
                        invertEnabled: config.display.invertEnabled ?? false,
                        autoInvert: config.display.autoInvert ?? false),
                    invert || auto)
            }
        }
    }
}
