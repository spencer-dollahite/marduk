import AppKit

/// Assembles the freshly built binary into <repo>/Marduk.app on the user's
/// Mac — nothing binary is committed; the bundle (icon included) is
/// generated in code at build time. A real bundle gives Marduk a stable
/// TCC identity (CFBundleIdentifier), a name and icon in System Settings,
/// and first-class citizenship with system services that ignore bare
/// binaries. The identity trio must stay identical: launchd label ==
/// codesign identifier == CFBundleIdentifier == "com.marduk.daemon".
enum Bundler {
    static let bundleID = Codesign.identifier

    static func bundlePath(projectDir: String) -> String {
        projectDir + "/Marduk.app"
    }

    static func executablePath(projectDir: String) -> String {
        bundlePath(projectDir: projectDir) + "/Contents/MacOS/marduk"
    }

    /// Walks up from an executable path until Package.swift appears.
    /// Handles both layouts: <repo>/Marduk.app/Contents/MacOS/marduk
    /// (3 hops) and <repo>/.build/arm64-apple-macosx/debug/marduk (4 hops).
    static func projectDir(fromExecutable path: String) -> String? {
        var url = URL(fileURLWithPath: path).standardized
        for _ in 0..<6 where url.path != "/" {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Package.swift").path) {
                return url.path
            }
        }
        return nil
    }

    /// Builds Marduk.app.new (structure, icon, Info.plist, binary), signs
    /// it, and atomically swaps it into <repo>/Marduk.app. The live bundle
    /// is never modified in place — a running daemon keeps its inode
    /// through the swap. Returns the bundle executable path, nil on failure
    /// (in which case the previous bundle, if any, is untouched).
    static func assemble(binaryPath: String, projectDir: String) -> String? {
        let fm = FileManager.default
        let bundle = bundlePath(projectDir: projectDir)
        let staging = bundle + ".new"
        let old = bundle + ".old"
        let contents = staging + "/Contents"

        do {
            try? fm.removeItem(atPath: staging)
            try fm.createDirectory(atPath: contents + "/MacOS",
                                   withIntermediateDirectories: true)
            try fm.createDirectory(atPath: contents + "/Resources",
                                   withIntermediateDirectories: true)
        } catch {
            fputs("[bundle] staging failed: \(error.localizedDescription)\n", stderr)
            return nil
        }

        // Icon: generated from the same M path as the repo logo. Failure is
        // non-fatal — the bundle ships iconless rather than not at all.
        let hasIcon = generateIcns(to: contents + "/Resources/marduk.icns",
                                   projectDir: projectDir)
        if !hasIcon {
            fputs("[bundle] icon generation failed — bundling without icon\n", stderr)
        }

        var info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": "Marduk",
            "CFBundleDisplayName": "Marduk",
            "CFBundleExecutable": "marduk",
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": Marduk.version,
            "CFBundleVersion": Marduk.version,
            "LSUIElement": true,
            "LSMinimumSystemVersion": "14.0",
            "NSPrincipalClass": "NSApplication",
            "NSHighResolutionCapable": true,
            "NSAppleEventsUsageDescription":
                "Marduk pauses and resumes media players (Music and Spotify) "
                + "while it speaks, and checks playback state via System Events.",
        ]
        if hasIcon { info["CFBundleIconFile"] = "marduk" }

        do {
            let plist = try PropertyListSerialization.data(
                fromPropertyList: info, format: .xml, options: 0)
            try plist.write(to: URL(fileURLWithPath: contents + "/Info.plist"),
                            options: .atomic)
            try "APPL????".write(toFile: contents + "/PkgInfo",
                                 atomically: true, encoding: .ascii)
            try fm.copyItem(atPath: binaryPath, toPath: contents + "/MacOS/marduk")
        } catch {
            fputs("[bundle] assembly failed: \(error.localizedDescription)\n", stderr)
            return nil
        }

        // Signing the staging bundle seals the nested executable; failure is
        // non-fatal (parity with the bare binary's unsigned fallback).
        Codesign.sign(bundleAt: staging)

        // Atomic swap: the running daemon (if executing from the old bundle)
        // keeps its inode; unlinking .old is safe.
        do {
            try? fm.removeItem(atPath: old)
            if fm.fileExists(atPath: bundle) {
                try fm.moveItem(atPath: bundle, toPath: old)
            }
            try fm.moveItem(atPath: staging, toPath: bundle)
            try? fm.removeItem(atPath: old)
        } catch {
            fputs("[bundle] swap failed: \(error.localizedDescription)\n", stderr)
            return nil
        }

        fputs("[bundle] assembled \(bundle)\n", stderr)
        return executablePath(projectDir: projectDir)
    }

    // MARK: - Icon (drawn in code — no binary assets in the repo)

    /// The M from assets/logo.svg: black rounded square, white M whose
    /// middle vertex reaches the baseline. Rendered per iconset size and
    /// packed with iconutil.
    private static func generateIcns(to icnsPath: String, projectDir: String) -> Bool {
        let fm = FileManager.default
        let iconset = projectDir + "/.build/marduk.iconset"
        do {
            try? fm.removeItem(atPath: iconset)
            try fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
        } catch {
            return false
        }

        let entries: [(name: String, pixels: Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32),
            ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256),
            ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for entry in entries {
            guard let png = iconPNG(pixels: entry.pixels) else { return false }
            let file = "\(iconset)/\(entry.name).png"
            guard (try? png.write(to: URL(fileURLWithPath: file))) != nil else {
                return false
            }
        }

        let result = run("/usr/bin/iconutil", "-c", "icns", iconset, "-o", icnsPath)
        if result.status != 0 {
            fputs("[bundle] iconutil failed: \(result.output)\n", stderr)
            return false
        }
        return true
    }

    private static func iconPNG(pixels: Int) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // Draw in the logo's 256-unit space; SVG is y-down, CG is y-up
        let scale = CGFloat(pixels) / 256
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: 256)
        ctx.scaleBy(x: 1, y: -1)

        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 256, height: 256),
                           cornerWidth: 48, cornerHeight: 48, transform: nil))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()

        let m = CGMutablePath()
        m.move(to: CGPoint(x: 58, y: 180))
        for point in [(58, 76), (88, 76), (128, 150), (168, 76), (198, 76),
                      (198, 180), (176, 180), (176, 108), (137, 178),
                      (119, 178), (80, 108), (80, 180)] {
            m.addLine(to: CGPoint(x: point.0, y: point.1))
        }
        m.closeSubpath()
        ctx.addPath(m)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillPath()

        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private static func run(_ launchPath: String, _ args: String...) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (-1, "Failed to launch \(launchPath): \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
