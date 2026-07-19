import Foundation
import AppKit
import ApplicationServices

/// One-shot diagnostic for `marduk audio-debug`.
///
/// Reproduce the problem state first (e.g. music playing on Firefox tab 1 +
/// a background YouTube video tab also playing), THEN run `marduk audio-debug`.
/// The dump tells us, definitively, what signals we have to distinguish
/// "music (duck/keep playing)" from "video (pause)" — especially for a tab
/// that is NOT in the foreground.
enum AudioDiagnostics {

    static func dump() {
        let ducker = AudioDucker()

        print("══════════════════════════════════════════════════════════")
        print(" marduk audio-debug")
        print("══════════════════════════════════════════════════════════")

        // 1) Which processes are actually emitting audio right now (CoreAudio HAL).
        print("\n── Audio-producing processes (CoreAudio) ──")
        let procs = ducker.audioProducingProcesses()
        if procs.isEmpty {
            print("  (none — nothing other than marduk is producing output)")
        } else {
            for p in procs {
                print("  PID \(p.pid): \(p.path)")
            }
        }

        // 2) Firefox accessibility tree — tab URLs + any audio markers.
        print("\n── Firefox accessibility tree ──")
        guard let firefox = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "org.mozilla.firefox" ||
            ($0.localizedName ?? "").range(of: "Firefox", options: .caseInsensitive) != nil
        }) else {
            print("  Firefox is not running.")
            print("\nDone.")
            return
        }
        print("  Firefox main PID: \(firefox.processIdentifier)")

        if !AXIsProcessTrusted() {
            print("  ⚠️  Accessibility permission NOT granted — AX tree unavailable.")
            print("\nDone.")
            return
        }

        let axApp = AXUIElementCreateApplication(firefox.processIdentifier)
        walk(axApp, depth: 0)

        print("\nDone. Paste this whole block back.")
    }

    // MARK: - AX tree walk

    private static let maxDepth = 22
    private static var nodesPrinted = 0
    private static let maxNodes = 8000

    /// Recurse the tree, printing only "interesting" nodes (tabs, web areas,
    /// anything carrying a URL, and any element whose role/attributes look
    /// audio-related) so the output stays readable but captures what we need.
    private static func walk(_ element: AXUIElement, depth: Int) {
        guard depth <= maxDepth, nodesPrinted < maxNodes else { return }

        let role = string(element, kAXRoleAttribute) ?? "?"
        let roleDesc = string(element, "AXRoleDescription") ?? ""
        let title = string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute) ?? ""
        let url = url(element)
        let value = string(element, kAXValueAttribute)

        let attrNames = attributeNames(element)
        let audioAttrs = attrNames.filter {
            let l = $0.lowercased()
            return l.contains("audio") || l.contains("mut") || l.contains("sound") || l.contains("play")
        }

        let looksTab = role == "AXRadioButton" || roleDesc.lowercased().contains("tab")
        let looksWeb = role == "AXWebArea"
        let interesting = looksTab || looksWeb || url != nil || !audioAttrs.isEmpty

        if interesting {
            let indent = String(repeating: "  ", count: min(depth, maxDepth))
            var line = "\(indent)[\(role)]"
            if !roleDesc.isEmpty, roleDesc != role { line += " (\(roleDesc))" }
            if !title.isEmpty { line += " title=\(quote(title))" }
            if let url { line += " url=\(quote(url))" }
            if let value, !value.isEmpty, looksTab || looksWeb { line += " value=\(quote(value))" }
            print(line)
            nodesPrinted += 1

            // For tabs/web areas, surface every audio-ish attribute with its value,
            // plus the full attribute-name list so we can spot anything we missed.
            if looksTab || looksWeb {
                for a in audioAttrs {
                    print("\(indent)    • \(a) = \(quote(string(element, a) ?? "<non-string>"))")
                }
                if looksTab {
                    print("\(indent)    attrs: \(attrNames.joined(separator: ", "))")
                }
            }
        }

        for child in children(element) {
            walk(child, depth: depth + 1)
        }
    }

    // MARK: - AX helpers

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let arr = ref as? [AXUIElement] else { return [] }
        return arr
    }

    private static func attributeNames(_ element: AXUIElement) -> [String] {
        var ref: CFArray?
        guard AXUIElementCopyAttributeNames(element, &ref) == .success,
              let names = ref as? [String] else { return [] }
        return names
    }

    private static func string(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else { return nil }
        if let s = ref as? String { return s }
        if let n = ref as? NSNumber { return n.stringValue }
        return nil
    }

    private static func url(_ element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &ref) == .success else { return nil }
        if let u = ref as? URL { return u.absoluteString }
        if let s = ref as? String { return s }
        return nil
    }

    private static func quote(_ s: String) -> String {
        let trimmed = s.replacingOccurrences(of: "\n", with: " ")
        let clipped = trimmed.count > 140 ? String(trimmed.prefix(140)) + "…" : trimmed
        return "\"\(clipped)\""
    }
}
