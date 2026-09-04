import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
#if canImport(FoundationModels)
import FoundationModels
#endif

/// `marduk ax-probe`: a one-shot diagnostic for the image-description
/// feature (`D`). Counts down, then dumps what the accessibility tree
/// says about the element under the POINTER — the element itself, a few
/// ancestors, and any image-shaped descendants — plus the front window's
/// document path, the Screen Recording grant, and the OS/model
/// availability that decides which description engine can run.
///
/// It exists because the one thing the design cannot know from a Linux
/// box is whether Messages exposes an attachment's FILE over AX (a full-
/// resolution rung) or only its pixels on screen (the capture rung).
/// Point at a photo in a conversation, run this, paste the block back.
///
/// Output goes to the INVOKING TERMINAL only, never the daemon log (the
/// `speak --debug` precedent): it can carry window content — short
/// attribute strings are printed verbatim, long ones by length — so the
/// header says to review before pasting anywhere public.
enum AXProbe {

    static let countdown = 3
    static let maxDescendants = 300
    static let maxDepth = 6
    static let maxAncestors = 4
    /// Strings up to this length print verbatim; longer ones print as a
    /// length. Enough to see "Image", "attachment.jpeg" or a file URL.
    static let verbatimLimit = 120

    static func run() {
        print("══════════════════════════════════════════════════════════")
        print(" marduk ax-probe — element under the pointer")
        print(" (may contain window content; review before pasting)")
        print("══════════════════════════════════════════════════════════")
        guard AXIsProcessTrusted() else {
            print("  Accessibility permission NOT granted for this binary —")
            print("  run it from a terminal that has the grant, or grant")
            print("  the marduk binary in Settings > Privacy > Accessibility.")
            return
        }
        for remaining in stride(from: countdown, through: 1, by: -1) {
            print("  Hover the pointer over the image… \(remaining)")
            fflush(stdout)
            Thread.sleep(forTimeInterval: 1)
        }

        let mouse = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let axPoint = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
        print("\n── Pointer ──")
        print("  AX coordinates (top-left origin): "
            + "\(Int(axPoint.x)), \(Int(axPoint.y))")

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        var elementRef: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(
            systemWide, Float(axPoint.x), Float(axPoint.y), &elementRef)
        guard err == .success, let element = elementRef else {
            print("  element-at-position failed (AX error \(err.rawValue))")
            return
        }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let app = NSRunningApplication(processIdentifier: pid)
        print("  App: \(app?.bundleIdentifier ?? "?") "
            + "(\(app?.localizedName ?? "?"), pid \(pid))")

        print("\n── Element under the pointer ──")
        describe(element, indent: "  ")

        print("\n── Ancestors (nearest first) ──")
        var current = element
        for _ in 0..<maxAncestors {
            guard let parent = parent(of: current) else { break }
            describe(parent, indent: "  ")
            print("  --")
            current = parent
        }

        print("\n── Image-shaped descendants (up to \(maxDescendants) nodes) ──")
        var visited = 0
        var found = 0
        walk(element, depth: 0, visited: &visited, found: &found)
        print("  visited \(visited) nodes, \(found) image-shaped")

        print("\n── Front window of that app ──")
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        if let window = frontWindow(of: axApp) {
            describe(window, indent: "  ",
                     attributes: [kAXRoleAttribute as String,
                                  kAXSubroleAttribute as String,
                                  kAXTitleAttribute as String,
                                  kAXDocumentAttribute as String,
                                  "AXURL"])
        } else {
            print("  (no focused/main/first window)")
        }

        print("\n── Engines ──")
        let os = ProcessInfo.processInfo.operatingSystemVersion
        print("  macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        print("  Screen Recording granted: "
            + (CGPreflightScreenCaptureAccess() ? "yes" : "NO"))
        print("  Apple on-device language model: \(appleModelState())")
        print("  Ollama binary: "
            + (OllamaServer.binaryPaths.first {
                FileManager.default.isExecutableFile(atPath: $0) } ?? "not found"))
        print("\nDone. Paste this block back.")
    }

    // MARK: - Printing

    static let interestingAttributes: [String] = [
        kAXRoleAttribute as String, kAXSubroleAttribute as String,
        kAXRoleDescriptionAttribute as String,
        kAXTitleAttribute as String, "AXDescription",
        kAXValueAttribute as String, kAXHelpAttribute as String,
        "AXURL", kAXDocumentAttribute as String, "AXFilename",
        kAXIdentifierAttribute as String,
        kAXPositionAttribute as String, kAXSizeAttribute as String,
    ]

    private static func describe(_ element: AXUIElement, indent: String,
                                 attributes: [String]? = nil) {
        AXUIElementSetMessagingTimeout(element, 0.5)
        let wanted = attributes ?? interestingAttributes
        var names: CFArray?
        let all = (AXUIElementCopyAttributeNames(element, &names) == .success)
            ? ((names as? [String]) ?? []) : []
        for name in wanted where all.contains(name) || attributes != nil {
            var ref: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(element, name as CFString, &ref)
            guard err == .success, let value = ref else {
                if attributes != nil {
                    print("\(indent)\(name): (error \(err.rawValue))")
                }
                continue
            }
            print("\(indent)\(name): \(render(value))")
        }
        let extras = all.filter { !wanted.contains($0) }
        if !extras.isEmpty {
            print("\(indent)other attributes: \(extras.joined(separator: ", "))")
        }
    }

    /// One line per value: type, and the content only when it is short.
    static func render(_ value: CFTypeRef) -> String {
        if let string = value as? String {
            return string.count <= verbatimLimit
                ? "\"\(string)\"" : "string, \(string.count) chars"
        }
        if let url = value as? URL {
            return "URL \(url.scheme ?? "?"): "
                + (url.isFileURL ? "file, .\(url.pathExtension)" : "\(url.host ?? "?")")
                + " (\(url.absoluteString.count) chars)"
        }
        if let number = value as? NSNumber { return "number \(number)" }
        if CFGetTypeID(value) == AXValueGetTypeID() {
            let axValue = value as! AXValue
            switch AXValueGetType(axValue) {
            case .cgPoint:
                var point = CGPoint.zero
                AXValueGetValue(axValue, .cgPoint, &point)
                return "point \(Int(point.x)), \(Int(point.y))"
            case .cgSize:
                var size = CGSize.zero
                AXValueGetValue(axValue, .cgSize, &size)
                return "size \(Int(size.width)) x \(Int(size.height))"
            default:
                return "AXValue type \(AXValueGetType(axValue).rawValue)"
            }
        }
        if CFGetTypeID(value) == AXUIElementGetTypeID() { return "an element" }
        if let array = value as? [Any] { return "array of \(array.count)" }
        if let data = value as? Data { return "data, \(data.count) bytes" }
        return "\(type(of: value))"
    }

    // MARK: - Tree

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, kAXParentAttribute as CFString, &ref) == .success,
              let raw = ref, CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        return (raw as! AXUIElement)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, kAXChildrenAttribute as CFString, &ref) == .success
        else { return [] }
        return (ref as? [AXUIElement]) ?? []
    }

    static let imageRoles: Set<String> = ["AXImage", "AXImageView", "AXCell"]

    private static func walk(_ element: AXUIElement, depth: Int,
                             visited: inout Int, found: inout Int) {
        guard depth <= maxDepth, visited < maxDescendants else { return }
        for child in children(of: element) {
            guard visited < maxDescendants else { return }
            visited += 1
            AXUIElementSetMessagingTimeout(child, 0.25)
            var roleRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            let role = (roleRef as? String) ?? "?"
            if imageRoles.contains(role) || role.lowercased().contains("image") {
                found += 1
                print("  [depth \(depth + 1)]")
                describe(child, indent: "    ")
            }
            walk(child, depth: depth + 1, visited: &visited, found: &found)
        }
    }

    private static func frontWindow(of axApp: AXUIElement) -> AXUIElement? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                   axApp, attribute as CFString, &ref) == .success,
               let raw = ref, CFGetTypeID(raw) == AXUIElementGetTypeID() {
                return (raw as! AXUIElement)
            }
        }
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }
        return windows.first
    }

    // MARK: - Engines

    /// Whether Apple's on-device model answers at all (macOS 26+, Apple
    /// Intelligence on). IMAGE input needs macOS 27 — reported separately
    /// by the OS line above.
    static func appleModelState() -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            // if-case, not a switch: a future case in this enum must
            // not break the build of a diagnostic
            if case .available = SystemLanguageModel.default.availability {
                return "available (images need macOS 27)"
            }
            return "unavailable — Apple Intelligence off, or unsupported"
        }
        return "needs macOS 26"
        #else
        return "not in this SDK"
        #endif
    }
}
