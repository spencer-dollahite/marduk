import XCTest
@testable import marduk

/// The Karabiner DRIVER can never run on CI (DriverKit extension, needs
/// interactive approval) — but the dangerous half of the integration is
/// Marduk rewriting the user's karabiner.json, and that is pure JSON
/// surgery. These fixtures pin the contract: adopt an existing Marduk
/// profile as-is (only our rule refreshed), bootstrap a clone otherwise,
/// never touch other profiles, and never write when nothing usable exists.
final class KarabinerRewriteTests: XCTestCase {

    private func profile(_ name: String, selected: Bool = false,
                         rules: [[String: Any]] = []) -> [String: Any] {
        ["name": name, "selected": selected,
         "complex_modifications": ["rules": rules]]
    }

    private func rewrite(_ profiles: [[String: Any]],
                         vendorId: Int = 5426, productId: Int? = nil)
        -> (root: [String: Any], userProfile: String?)? {
        DaemonServer.rewriteKarabinerConfig(["profiles": profiles],
                                            key: "equal_sign",
                                            vendorId: vendorId,
                                            productId: productId)
    }

    private func profiles(of root: [String: Any]) -> [[String: Any]] {
        root["profiles"] as? [[String: Any]] ?? []
    }

    private func rules(of profile: [String: Any]) -> [[String: Any]] {
        ((profile["complex_modifications"] as? [String: Any])?["rules"]
            as? [[String: Any]]) ?? []
    }

    func testBootstrapsMardukProfileFromSelected() {
        let result = rewrite([profile("Default", selected: true),
                              profile("Gaming")])
        XCTAssertEqual(result?.userProfile, "Default")
        let all = profiles(of: result!.root)
        XCTAssertEqual(all.count, 3)
        let marduk = all.first { ($0["name"] as? String) == "Marduk" }
        XCTAssertNotNil(marduk)
        XCTAssertEqual(marduk?["selected"] as? Bool, false)
        XCTAssertEqual(rules(of: marduk!).count, 2)  // read button + panic chord
    }

    func testAdoptsExistingMardukProfileAndRefreshesOnlyOurRule() {
        let userRule: [String: Any] = ["description": "my zoom keys"]
        let staleMarduk: [String: Any] = ["description": "Marduk read button (old)"]
        let result = rewrite([profile("Default", selected: true),
                              profile("Marduk", rules: [userRule, staleMarduk])])
        let all = profiles(of: result!.root)
        XCTAssertEqual(all.count, 2)  // adopted, not duplicated
        let marduk = all.first { ($0["name"] as? String) == "Marduk" }!
        let r = rules(of: marduk)
        XCTAssertEqual(r.count, 3)  // stale ours removed; read + panic added
        XCTAssertTrue((r[0]["description"] as? String)?
            .hasPrefix("Marduk read button") == true)  // ours first
        XCTAssertTrue((r[1]["description"] as? String)?
            .hasPrefix("Marduk panic chord") == true)
        XCTAssertEqual(r[2]["description"] as? String, "my zoom keys")
    }

    func testPanicChordKillsViaShellUpstreamOfMarduk() {
        let rule = DaemonServer.panicRule()
        let manipulators = rule["manipulators"] as! [[String: Any]]
        XCTAssertEqual(manipulators.count, 1)
        let to = manipulators[0]["to"] as! [[String: Any]]
        XCTAssertEqual(to.first?["shell_command"] as? String,
                       "/usr/bin/pkill -9 marduk")
        let from = manipulators[0]["from"] as! [String: Any]
        XCTAssertEqual(from["key_code"] as? String, "delete_or_backspace")
    }

    func testCrashRecoveryFindsUserProfileWhenMardukIsSelected() {
        // After a crash the selected profile can still be "Marduk" — the
        // user's own profile must be found among the others
        let result = rewrite([profile("Marduk", selected: true),
                              profile("Default")])
        XCTAssertEqual(result?.userProfile, "Default")
    }

    func testOtherProfilesAreNeverTouched() {
        let gaming = profile("Gaming", rules: [["description": "wasd stuff"]])
        let result = rewrite([profile("Default", selected: true), gaming])
        let all = profiles(of: result!.root)
        let gamingAfter = all.first { ($0["name"] as? String) == "Gaming" }!
        XCTAssertEqual(rules(of: gamingAfter).count, 1)
        XCTAssertEqual(rules(of: gamingAfter)[0]["description"] as? String,
                       "wasd stuff")
    }

    func testNothingUsableMeansNoWrite() {
        XCTAssertNil(rewrite([]))
        XCTAssertNil(DaemonServer.rewriteKarabinerConfig(
            [:], key: "equal_sign", vendorId: 5426, productId: nil))
    }

    func testRuleIsDeviceScopedOnBothManipulators() {
        let rule = DaemonServer.readButtonRule(key: "equal_sign",
                                               vendorId: 5426, productId: 83)
        let manipulators = rule["manipulators"] as! [[String: Any]]
        XCTAssertEqual(manipulators.count, 2)
        for m in manipulators {
            let conditions = m["conditions"] as? [[String: Any]] ?? []
            let device = conditions.first { ($0["type"] as? String) == "device_if" }
            XCTAssertNotNil(device, "both manipulators must be device-scoped — "
                + "an unscoped rule ate the real keyboard's equals key")
            let identifiers = device?["identifiers"] as? [[String: Any]]
            XCTAssertEqual(identifiers?.first?["vendor_id"] as? Int, 5426)
            XCTAssertEqual(identifiers?.first?["product_id"] as? Int, 83)
        }
        // The Marduk-up manipulator keeps its variable condition too
        let first = manipulators[0]["conditions"] as! [[String: Any]]
        XCTAssertTrue(first.contains { ($0["type"] as? String) == "variable_if" })
    }

    func testVendorZeroMeansNoDeviceScoping() {
        let rule = DaemonServer.readButtonRule(key: "equal_sign",
                                               vendorId: 0, productId: nil)
        let manipulators = rule["manipulators"] as! [[String: Any]]
        for m in manipulators {
            let conditions = m["conditions"] as? [[String: Any]] ?? []
            XCTAssertFalse(conditions.contains { ($0["type"] as? String) == "device_if" })
        }
    }

    // MARK: - The user's own rules (per-rule profile targeting)

    private func userRule(_ description: String,
                          profiles: [String]) -> [String: Any] {
        ["profiles": profiles,
         "rule": ["description": description,
                  "manipulators": [["type": "basic",
                                    "from": ["key_code": "f"],
                                    "to": [["shell_command": "open -a FaceTime"]]]]]]
    }

    private func entries(_ items: [[String: Any]]) -> [KarabinerRules.Entry] {
        KarabinerRules.parse(try! JSONSerialization.data(withJSONObject: items))
    }

    private func rewrite(_ profiles: [[String: Any]],
                         userRules: [KarabinerRules.Entry])
        -> (root: [String: Any], userProfile: String?)? {
        DaemonServer.rewriteKarabinerConfig(["profiles": profiles],
                                            key: "equal_sign",
                                            vendorId: 5426, productId: nil,
                                            userRules: userRules)
    }

    private func named(_ root: [String: Any], _ name: String) -> [String: Any]? {
        profiles(of: root).first { ($0["name"] as? String) == name }
    }

    private func descriptions(_ profile: [String: Any]?) -> [String] {
        rules(of: profile ?? [:]).compactMap { $0["description"] as? String }
    }

    /// The default target is Marduk's own profile, and a rule that lands
    /// there must leave the user's profile completely alone.
    func testMardukTargetedRuleNeverTouchesTheUserProfile() {
        let existing = ["description": "Zoom In", "manipulators": [["type": "basic"]]]
            as [String: Any]
        let result = rewrite([profile("Default", selected: true, rules: [existing]),
                              profile("Marduk")],
                             userRules: entries([userRule("FaceTime",
                                                          profiles: ["marduk"])]))
        XCTAssertTrue(descriptions(named(result!.root, "Marduk"))
            .contains(KarabinerRules.tagPrefix + "FaceTime"))
        XCTAssertEqual(descriptions(named(result!.root, "Default")), ["Zoom In"])
    }

    /// "Sometimes I want both" — the user's ruling, so one entry can name
    /// both profiles and appear in each.
    func testBothTargetsLandInBothProfiles() {
        let result = rewrite([profile("Default", selected: true),
                              profile("Marduk")],
                             userRules: entries([userRule("FaceTime",
                                                 profiles: ["marduk", "user"])]))
        let tagged = KarabinerRules.tagPrefix + "FaceTime"
        XCTAssertTrue(descriptions(named(result!.root, "Marduk")).contains(tagged))
        XCTAssertTrue(descriptions(named(result!.root, "Default")).contains(tagged))
    }

    /// Reversibility is the whole point of tagging: dropping a rule from
    /// rules.json has to remove it from the user's own profile too, or
    /// Marduk can add bindings there but never take them back.
    func testDeletedRuleLeavesTheUserProfile() {
        let applied = rewrite([profile("Default", selected: true),
                               profile("Marduk")],
                              userRules: entries([userRule("FaceTime",
                                                  profiles: ["user"])]))!
        let after = rewrite(profiles(of: applied.root), userRules: [])!
        XCTAssertEqual(descriptions(named(after.root, "Default")), [])
    }

    /// A user with no rules at all must get a profile back untouched —
    /// not one newly furnished with an empty complex_modifications block.
    func testUserProfileIsUntouchedWhenThereIsNothingToDo() {
        let plain: [String: Any] = ["name": "Default", "selected": true]
        let result = rewrite([plain], userRules: [])
        XCTAssertNil(named(result!.root, "Default")?["complex_modifications"])
    }

    /// Marduk's own rules stay first, ahead of anything the user carries.
    func testOurOwnRulesStayOnTop() {
        let result = rewrite([profile("Default", selected: true)],
                             userRules: entries([userRule("FaceTime",
                                                          profiles: ["marduk"])]))
        let ours = descriptions(named(result!.root, "Marduk")).prefix(2)
        XCTAssertTrue(ours.allSatisfy { $0.hasPrefix("Marduk read button")
                                     || $0.hasPrefix("Marduk panic chord") })
    }

    /// The strip must sweep EVERY non-Marduk profile: a tagged rule left
    /// in a profile that is no longer the resolved user profile would
    /// otherwise be orphaned forever.
    func testDeletedRuleLeavesEveryProfile() {
        let tagged: [String: Any] = [
            "description": KarabinerRules.tagPrefix + "FaceTime",
            "manipulators": [["type": "basic"]]]
        let result = rewrite([profile("Default", selected: true),
                              profile("Laptop", rules: [tagged]),
                              profile("Marduk")],
                             userRules: [])
        XCTAssertEqual(descriptions(named(result!.root, "Laptop")), [])
    }

    /// …while an untagged rule in that same swept profile is untouchable.
    func testSweepNeverTouchesUntaggedRulesInOtherProfiles() {
        let own: [String: Any] = ["description": "Zoom In",
                                  "manipulators": [["type": "basic"]]]
        let tagged: [String: Any] = [
            "description": KarabinerRules.tagPrefix + "FaceTime",
            "manipulators": [["type": "basic"]]]
        let result = rewrite([profile("Default", selected: true),
                              profile("Laptop", rules: [own, tagged])],
                             userRules: [])
        XCTAssertEqual(descriptions(named(result!.root, "Laptop")), ["Zoom In"])
    }
}
