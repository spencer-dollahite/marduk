import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import ImageIO
import ScreenCaptureKit

/// Pure geometry for the image-description capture rung. AX frames and
/// window bounds are both TOP-LEFT-origin global screen points (the AX
/// position attribute and `CGWindowListCopyWindowInfo` bounds agree, and
/// ScreenCaptureKit's `sourceRect` is window-relative in the same
/// orientation), so the math is plain subtraction — kept pure so the
/// tests can pin it, since a sign error here silently describes the
/// wrong part of the screen.
///
/// ZOOM-PROOF BY CONSTRUCTION (user requirement 2026-09-04): macOS zoom
/// magnifies the composited framebuffer and nothing else. The pointer
/// position, AX hit-testing, AX frames, and window bounds all live in
/// the LOGICAL screen space zoom never touches, and a WINDOW capture is
/// rendered from the window's own backing store — un-zoomed, un-inverted
/// — so the crop lands on the same pixels the AX frame names whatever
/// the zoom level. The one thing that would break under zoom is a
/// DISPLAY capture (it would hand the engines a magnified crop of the
/// framebuffer, offset by the pan), which is why a display-scoped content
/// filter and the CoreGraphics display-image call are forbidden in this
/// file by test.
enum ImageRegion {
    /// An element covering more than this much of its window is a
    /// container (a transcript, a page), not an image.
    static let maxElementFraction: CGFloat = 0.75
    /// Below this on either side it is an icon or a glyph, not a picture.
    static let minSide: CGFloat = 16
    /// Longest side handed to the engines. Vision's OCR likes detail;
    /// the LLM rungs downscale further themselves.
    static let maxSide = 1600

    static func isImageShaped(element: CGRect, window: CGRect) -> Bool {
        guard element.width >= minSide, element.height >= minSide,
              window.width > 0, window.height > 0 else { return false }
        let fraction = (element.width * element.height)
            / (window.width * window.height)
        return fraction <= maxElementFraction
    }

    /// The element's rect in window-relative points, clipped to the
    /// window; nil when they don't overlap (a stale frame).
    static func windowRelative(element: CGRect, window: CGRect) -> CGRect? {
        let clipped = element.intersection(window)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else {
            return nil
        }
        return CGRect(x: clipped.minX - window.minX, y: clipped.minY - window.minY,
                      width: clipped.width, height: clipped.height)
    }

    /// Output pixel size for a capture of `points` at a backing scale.
    static func pixelSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        (max(1, Int((points.width * scale).rounded())),
         max(1, Int((points.height * scale).rounded())))
    }

    /// Fit inside `maxSide` keeping aspect; never upscales.
    static func downscaled(width: Int, height: Int, maxSide: Int) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard longest > maxSide, longest > 0 else { return (width, height) }
        let factor = Double(maxSide) / Double(longest)
        return (max(1, Int((Double(width) * factor).rounded())),
                max(1, Int((Double(height) * factor).rounded())))
    }

    /// File extensions worth opening as an image. The bytes are still
    /// checked by ImageIO before anything is decoded.
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif",
        "webp", "bmp", "avif", "jp2",
    ]

    static func looksLikeImageFile(_ url: URL) -> Bool {
        url.isFileURL && imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Element roles that are the picture itself.
    static let imageRoles: Set<String> = ["AXImage"]

    /// AX labels that name the KIND of thing rather than the thing —
    /// speaking "labeled image" before a description is noise.
    static let genericLabels: Set<String> = [
        "image", "photo", "picture", "attachment", "img", "graphic",
        "unknown", "untitled",
    ]

    static func isGenericLabel(_ label: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return trimmed.isEmpty || genericLabels.contains(trimmed)
    }
}

/// Where the pixels came from — logged by name, never with content.
enum ImageSource: String {
    case elementFile = "element file"       // AX handed us a file URL
    case windowDocument = "window document" // the front window's document is an image
    case elementCapture = "element capture" // screenshot of the image element
    case windowCapture = "window capture"   // no image-shaped element: the whole window
    case screen = "whole screen"            // DD: every window on the display, composited
}

/// Where a captured window lands on the display canvas. CGContext draws
/// bottom-left-up in pixels; window bounds and display bounds are
/// top-left-origin global points. Pure, tested — a flipped y here would
/// describe a screen with its windows upside down and nobody could tell.
enum ScreenComposite {
    /// At most this many windows are captured, front-most first — the
    /// ones behind that are hidden anyway.
    static let windowCap = 24

    static func placement(window: CGRect, display: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: (window.minX - display.minX) * scale,
               y: (display.maxY - window.maxY) * scale,
               width: window.width * scale,
               height: window.height * scale)
    }
}

struct AcquiredImage {
    let image: CGImage
    let source: ImageSource
}

/// What the accessibility tree says about the spot under the pointer.
/// Gathered on MAIN (element-at-position and a handful of attribute
/// reads, every call on a 0.25s timeout); everything slow happens in
/// `ImageAcquire.acquire` off-main.
struct LocatedElement {
    var pid: pid_t?
    var bundleID: String?
    /// The image node's own AX title/description — user content, spoken
    /// as "labeled …" when it says more than "image".
    var label: String?
    /// The image node's frame if one was found, else the element's.
    var frame: CGRect?
    var imageShaped = false
    var fileURL: URL?      // rung 1
    var documentURL: URL?  // rung 2
    var axFailed = false
}

enum ImageAcquire {

    static let fileSizeCap = 50 * 1024 * 1024
    static let descendantBudget = 200
    static let descendantDepth = 5
    static let ancestorLimit = 3

    // MARK: - AX step (main thread)

    /// `pointer` in AppKit's bottom-left-origin screen coordinates
    /// (`NSEvent.mouseLocation`); converted to AX's top-left origin here.
    static func locate(pointer: CGPoint) -> LocatedElement {
        var located = LocatedElement()
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let axPoint = CGPoint(x: pointer.x, y: primaryHeight - pointer.y)

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        var elementRef: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(
            systemWide, Float(axPoint.x), Float(axPoint.y), &elementRef)
        guard err == .success, let element = elementRef else {
            fputs("[describe] element-at-position failed (\(err.rawValue))\n", stderr)
            located.axFailed = true
            located.pid = windowOwner(at: axPoint)
            return located
        }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        located.pid = pid
        located.bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        AXUIElementSetMessagingTimeout(element, 0.25)

        // The picture itself: the element, an image-shaped descendant
        // under the pointer, or an image ancestor — in that order.
        let (picture, pictureVia) = imageNode(from: element, at: axPoint)
        let node = picture ?? element
        located.frame = frame(of: node)
        located.label = label(of: node)
        located.fileURL = fileURL(of: node)
            ?? (picture == nil ? nil : fileURL(of: element))

        // Rung 2: the window's document, when that document is an image
        // (Preview, and whatever else publishes AXDocument for one).
        var windowFrame: CGRect?
        var windowDocument = "none"
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        if let window = frontWindow(of: axApp) {
            AXUIElementSetMessagingTimeout(window, 0.25)
            if let doc = documentURL(of: window) {
                windowDocument = describeURL(doc)
                if ImageRegion.looksLikeImageFile(doc) { located.documentURL = doc }
            }
            windowFrame = frame(of: window)
            if let windowFrame, let elementFrame = located.frame {
                located.imageShaped = ImageRegion.isImageShaped(
                    element: elementFrame, window: windowFrame)
            }
        }

        // THE PROBE, IN THE LOG (user request 2026-09-04: "copy the usual
        // log" must be enough to debug this). Everything below is AX
        // vocabulary, sizes, and verdicts — no title, description, value
        // or path ever; labels by length, URLs by scheme and extension.
        let ancestors = ancestorRoles(of: element, limit: ancestorLimit)
        let ancestorText: String = ancestors.isEmpty ? "none" : ancestors.joined(separator: " > ")
        let pictureText: String = picture == nil ? "" : " " + roleSummary(node)
        let line1: String = "[describe] probe: element " + roleSummary(element)
            + ", ancestors " + ancestorText
            + "; picture node: " + pictureVia + pictureText
        fputs(line1 + "\n", stderr)

        var labelText = "none"
        if let label = located.label {
            labelText = "\(label.count) chars"
            if ImageRegion.isGenericLabel(label) { labelText += " (generic)" }
        }
        let line2: String = "[describe] probe: node attrs " + attributeSummary(node)
            + "; label " + labelText
            + "; AXURL " + urlSummary(node, "AXURL")
            + "; AXDocument " + urlSummary(node, kAXDocumentAttribute as String)
        fputs(line2 + "\n", stderr)

        let elementSize: String = sizeText(located.frame)
        let windowSize: String = sizeText(windowFrame)
        let shaped: String = located.imageShaped ? "image-shaped" : "not image-shaped"
        let line3: String = "[describe] probe: element " + elementSize
            + " in window " + windowSize + " → " + shaped
            + "; window document " + windowDocument
        fputs(line3 + "\n", stderr)
        return located
    }

    // MARK: - Probe summaries (AX vocabulary only — safe for the log)

    private static func sizeText(_ rect: CGRect?) -> String {
        guard let rect else { return "no frame" }
        return "\(Int(rect.width))x\(Int(rect.height))"
    }

    private static func roleSummary(_ element: AXUIElement) -> String {
        let role = self.role(of: element)
        let subrole = (attribute(element, kAXSubroleAttribute as String) as? String) ?? ""
        return subrole.isEmpty ? (role.isEmpty ? "?" : role) : "\(role)/\(subrole)"
    }

    /// Which of the attributes that matter here the node actually has.
    static let probeAttributes: [String] = [
        kAXTitleAttribute as String, "AXDescription", kAXValueAttribute as String,
        "AXURL", kAXDocumentAttribute as String, "AXFilename",
        kAXHelpAttribute as String, kAXIdentifierAttribute as String,
    ]

    private static func attributeSummary(_ element: AXUIElement) -> String {
        var namesRef: CFArray?
        guard AXUIElementCopyAttributeNames(element, &namesRef) == .success,
              let names = namesRef as? [String] else { return "unreadable" }
        let present = probeAttributes.filter { names.contains($0) }
        return present.isEmpty ? "none of interest (\(names.count) total)"
            : present.joined(separator: " ") + " (\(names.count) total)"
    }

    /// "file .jpeg" / "https" / "none" — never the URL itself.
    private static func describeURL(_ url: URL) -> String {
        url.isFileURL
            ? "file ." + (url.pathExtension.isEmpty ? "(no extension)" : url.pathExtension.lowercased())
            : (url.scheme ?? "unknown scheme")
    }

    private static func urlSummary(_ element: AXUIElement, _ name: String) -> String {
        guard let raw = attribute(element, name) else { return "none" }
        if let url = raw as? URL { return describeURL(url) }
        if let path = raw as? String {
            if path.hasPrefix("/") { return describeURL(URL(fileURLWithPath: path)) }
            if let url = URL(string: path) { return describeURL(url) }
            return "string, \(path.count) chars"
        }
        return "\(type(of: raw))"
    }

    private static func ancestorRoles(of element: AXUIElement, limit: Int) -> [String] {
        var roles: [String] = []
        var current = element
        for _ in 0..<limit {
            guard let up = parent(of: current) else { break }
            AXUIElementSetMessagingTimeout(up, 0.25)
            roles.append(roleSummary(up))
            current = up
        }
        return roles
    }

    /// Off-main. Runs the rungs in fidelity order.
    enum Outcome {
        case image(AcquiredImage)
        case needsScreenRecording
        case noWindow
        case failed(String)   // fixed vocabulary, never content
    }

    static func acquire(_ located: LocatedElement, pointer: CGPoint) async -> Outcome {
        if let url = located.fileURL, let image = loadImage(url) {
            return .image(AcquiredImage(image: image, source: .elementFile))
        }
        if let url = located.documentURL, let image = loadImage(url) {
            return .image(AcquiredImage(image: image, source: .windowDocument))
        }
        guard CGPreflightScreenCaptureAccess() else { return .needsScreenRecording }
        return await capture(located, pointer: pointer)
    }

    // MARK: - Rungs 1-2: files

    /// Decode through ImageIO's thumbnail path: it verifies the bytes are
    /// an image, handles HEIC, and downsamples in one step.
    static func loadImage(_ url: URL) -> CGImage? {
        guard url.isFileURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue, size <= fileSizeCap,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: ImageRegion.maxSide,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - DD: the whole display

    /// Every on-screen window on the display under the pointer, captured
    /// one by one and composited back to front onto a canvas the size of
    /// the display. NOT a display capture on purpose: window captures come
    /// from the backing store — un-zoomed and pre-inversion — so the
    /// composite is the logical screen whatever zoom is showing, which is
    /// the whole point for a zoomed-in user asking "what is on my screen".
    /// Marduk's own windows (overlay, palette, key bar) are left out.
    static func captureScreen(pointer: CGPoint) async -> Outcome {
        guard CGPreflightScreenCaptureAccess() else { return .needsScreenRecording }
        guard let screen = NSScreen.screens.first(where: {
                  NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main,
              let number = screen.deviceDescription[
                  NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return .noWindow }
        let display = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        let scale = screen.backingScaleFactor
        let stack = windowStack(on: display)
        guard !stack.isEmpty else { return .noWindow }
        do {
            let content = try await SCShareableContent
                .excludingDesktopWindows(true, onScreenWindowsOnly: true)
            var byID: [CGWindowID: SCWindow] = [:]
            for window in content.windows { byID[window.windowID] = window }
            let pixels = ImageRegion.pixelSize(points: display.size, scale: scale)
            guard let canvas = CGContext(
                data: nil, width: pixels.width, height: pixels.height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return .failed("canvas") }
            canvas.setFillColor(CGColor(gray: 0.12, alpha: 1))
            canvas.fill(CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
            var drawn = 0
            // Front-most `windowCap` windows, drawn back to front
            for entry in stack.prefix(ScreenComposite.windowCap).reversed() {
                guard let window = byID[entry.id] else { continue }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                config.showsCursor = false
                config.captureResolution = .best
                let size = ImageRegion.pixelSize(points: entry.bounds.size, scale: scale)
                config.width = size.width
                config.height = size.height
                guard let image = try? await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config) else { continue }
                canvas.draw(image, in: ScreenComposite.placement(
                    window: entry.bounds, display: display, scale: scale))
                drawn += 1
            }
            guard drawn > 0, let image = canvas.makeImage() else { return .noWindow }
            fputs("[describe] screen: \(drawn) of \(stack.count) windows composited, "
                + "\(pixels.width)x\(pixels.height)\n", stderr)
            return .image(AcquiredImage(image: image, source: .screen))
        } catch {
            fputs("[describe] screen capture failed: \(error.localizedDescription)\n",
                  stderr)
            return .failed("capture")
        }
    }

    /// On-screen windows touching the display, front to back, minus our
    /// own and the invisible. Every layer: the menu bar and the Dock are
    /// part of "what is on my screen".
    static func windowStack(on display: CGRect) -> [(id: CGWindowID, bounds: CGRect)] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        var stack: [(CGWindowID, CGRect)] = []
        for info in list {
            guard let number = info[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 2, bounds.height >= 2,
                  bounds.intersects(display) else { continue }
            if let owner = info[kCGWindowOwnerPID as String] as? Int32,
               owner == getpid() { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.1 { continue }
            stack.append((number, bounds))
        }
        return stack
    }

    // MARK: - Rung 3: capture

    /// Screenshot the window under the pointer (never the display —
    /// other windows' content is not ours to read), cropped to the image
    /// element when one was found. Backing-store capture: un-zoomed and
    /// pre-inversion, so the AX frame coordinates agree with the pixels.
    private static func capture(_ located: LocatedElement, pointer: CGPoint) async -> Outcome {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let axPoint = CGPoint(x: pointer.x, y: primaryHeight - pointer.y)
        guard let hit = windowUnderPointer(axPoint, pid: located.pid) else {
            return .noWindow
        }
        let (windowID, bounds) = hit
        let scale = NSScreen.screens.first(where: {
            NSMouseInRect(pointer, $0.frame, false) })?.backingScaleFactor ?? 2
        do {
            let content = try await SCShareableContent
                .excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID })
            else { return .noWindow }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.showsCursor = false
            config.captureResolution = .best
            var source = ImageSource.windowCapture
            var rect = CGRect(origin: .zero, size: bounds.size)
            if located.imageShaped, let elementFrame = located.frame,
               let relative = ImageRegion.windowRelative(element: elementFrame,
                                                         window: bounds) {
                rect = relative
                source = .elementCapture
            }
            config.sourceRect = rect
            let pixels = ImageRegion.pixelSize(points: rect.size, scale: scale)
            config.width = pixels.width
            config.height = pixels.height
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
            return .image(AcquiredImage(image: image, source: source))
        } catch {
            fputs("[describe] capture failed: \(error.localizedDescription)\n", stderr)
            return .failed("capture")
        }
    }

    /// Front-to-back window list, first normal-layer window containing
    /// the point (owned by `pid` when known).
    static func windowUnderPointer(_ point: CGPoint, pid: pid_t?) -> (CGWindowID, CGRect)? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.contains(point) else { continue }
            if let pid, (info[kCGWindowOwnerPID as String] as? Int32) != pid { continue }
            return (number, bounds)
        }
        return nil
    }

    private static func windowOwner(at point: CGPoint) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.contains(point),
                  let owner = info[kCGWindowOwnerPID as String] as? Int32 else { continue }
            return owner
        }
        return nil
    }

    // MARK: - AX helpers

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success
        else { return nil }
        return ref
    }

    private static func role(of element: AXUIElement) -> String {
        (attribute(element, kAXRoleAttribute as String) as? String) ?? ""
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let posRef = attribute(element, kAXPositionAttribute as String),
              let sizeRef = attribute(element, kAXSizeAttribute as String),
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func label(of element: AXUIElement) -> String? {
        for name in [kAXTitleAttribute as String, "AXDescription"] {
            if let value = attribute(element, name) as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return String(trimmed.prefix(120)) }
            }
        }
        return nil
    }

    /// A `file://` URL the element publishes for itself — AXURL first
    /// (what a file-backed image carries), then AXDocument. Remote URLs
    /// are ignored on purpose: a web image's address is not ours to
    /// fetch, and the capture rung already has those pixels.
    private static func fileURL(of element: AXUIElement) -> URL? {
        for name in ["AXURL", kAXDocumentAttribute as String] {
            guard let raw = attribute(element, name) else { continue }
            let url = (raw as? URL)
                ?? (raw as? String).flatMap { path in
                    path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(string: path)
                }
            if let url, ImageRegion.looksLikeImageFile(url) { return url }
        }
        return nil
    }

    private static func documentURL(of window: AXUIElement) -> URL? {
        guard let raw = attribute(window, kAXDocumentAttribute as String) else { return nil }
        if let url = raw as? URL { return url }
        guard let path = raw as? String else { return nil }
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(string: path)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        guard let raw = attribute(element, kAXParentAttribute as String),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    /// The image node nearest the pointer: the element itself when it is
    /// one; else a budgeted descent for an AXImage whose frame contains
    /// the point; else a short climb (a hit-test can land on a caption or
    /// overlay sitting inside the image).
    private static func imageNode(from element: AXUIElement,
                                  at point: CGPoint) -> (AXUIElement?, String) {
        if ImageRegion.imageRoles.contains(role(of: element)) { return (element, "the element") }
        var visited = 0
        if let hit = descend(element, at: point, depth: 0, visited: &visited) {
            return (hit, "descendant (\(visited) visited)")
        }
        var current = element
        for step in 1...ancestorLimit {
            guard let up = parent(of: current) else { break }
            if ImageRegion.imageRoles.contains(role(of: up)) { return (up, "ancestor \(step)") }
            current = up
        }
        return (nil, "none (\(visited) descendants visited)")
    }

    private static func descend(_ element: AXUIElement, at point: CGPoint,
                                depth: Int, visited: inout Int) -> AXUIElement? {
        guard depth < descendantDepth, visited < descendantBudget else { return nil }
        for child in children(of: element) {
            guard visited < descendantBudget else { return nil }
            visited += 1
            AXUIElementSetMessagingTimeout(child, 0.25)
            let childFrame = frame(of: child)
            if let childFrame, !childFrame.contains(point) { continue }
            if ImageRegion.imageRoles.contains(role(of: child)) { return child }
            if let hit = descend(child, at: point, depth: depth + 1, visited: &visited) {
                return hit
            }
        }
        return nil
    }

    private static func frontWindow(of axApp: AXUIElement) -> AXUIElement? {
        for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let raw = attribute(axApp, name as String),
               CFGetTypeID(raw) == AXUIElementGetTypeID() {
                return (raw as! AXUIElement)
            }
        }
        return (attribute(axApp, kAXWindowsAttribute as String) as? [AXUIElement])?.first
    }
}
