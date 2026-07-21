import Foundation

/// Marduk configuration, loaded from ~/.config/marduk/config.json
struct MardukConfig: Codable {
    var ducking: DuckingConfig = DuckingConfig()
    var speech: SpeechConfig = SpeechConfig()
    var display: DisplayConfig = DisplayConfig()
    // Optional: existing config.json files lack this key, and a decode
    // failure would silently reset the whole file to defaults
    var keyboard: KeyboardConfig? = KeyboardConfig()
    var verbalizer: VerbalizerConfig? = VerbalizerConfig()
    var update: UpdateConfig? = UpdateConfig()
    var overlay: OverlayConfig? = OverlayConfig()

    // Every field below is Optional: synthesized Codable treats non-Optional
    // keys as REQUIRED (property defaults are ignored on decode), so a
    // hand-written partial block ("keyboard": {"typingRescue": false}) would fail
    // the whole decode — and load() resets a failed decode to defaults,
    // wiping voice/rate. Defaults are applied at the consumption site.
    struct KeyboardConfig: Codable {
        var escapeHoldMs: Int? = 400     // hold Escape this long in INSERT → NORMAL
        var typingBurstMs: Int? = 300    // typing-rescue burst window
        var typingRescue: Bool? = true   // false disables typing rescue
        var typingEcho: Bool? = false    // speak characters typed in INSERT
        var commandEcho: Bool? = true    // speak characters typed after ":"
        var commandPalette: Bool? = true // dmenu-style panel while typing a ":" command
        var palettePosition: String? = "pointer" // "pointer" | "center" — pointer is the
                                                 // only placement zoom always keeps in view
        var speedKeys: Bool? = false     // Option+Up/Down nudge speech rate (NORMAL/VISUAL)
        var toggleSound: String? = "speech" // "speech" | "earcon" — Ctrl+Option+M feedback
        var readMotions: Bool? = true    // vim motions inside a read: b/w hjkl ( ) { } 0 gg G . / ?
        var karabinerReadKey: String? = "equal_sign" // Karabiner key_code the read button sends
                                                     // (Naga side button 12 = the = key)
        var dialogAlerts: Bool? = true   // LEGACY toggle — dialogLevel wins when present
        var dialogLevel: String? = "all" // all | system | off (system = only central OS prompts)
        var follow: Bool? = true         // the view follows the read (Preview pages, web scroll)
        var karabinerReadVendorId: Int? = 5426   // device scope for the read-button rule (5426 = Razer; 0 = any device)
        var karabinerReadProductId: Int?         // optional tighter scope (see Karabiner-EventViewer)
    }

    struct OverlayConfig: Codable {
        var borderEnabled: Bool? = false      // colored mode border at screen edges (opt-in)
        var pointerEnabled: Bool? = false     // mode-colored dot following the pointer (opt-in)
        var thickness: Int? = 6               // border thickness, points
        var pointerSize: Int? = 28            // dot diameter, points
        var normalColor: String? = "#FF3B30"  // red; "none" or "" hides in that mode
        var insertColor: String? = "#34C759"  // green
        var visualColor: String? = "#007AFF"  // blue
        var readingColor: String? = "#AF52DE" // purple — while a read captures the keyboard
    }

    struct UpdateConfig: Codable {
        var checkHours: Int? = 24   // periodic update-check interval; 0 disables
        var auto: Bool? = true      // install automatically (silently, never mid-read)
    }

    struct VerbalizerConfig: Codable {
        var level: String? = "most"     // none | some | most | all
        var symbols: [String: String]?  // overrides, e.g. {"*": "asterisk", "->": "maps to", "%": ""}
        var hashes: Bool? = true        // abbreviate hex digests: "md5 ending in 2 7 e"
        var identifiers: Bool? = true   // split camelCase / snake_case into words
    }

    struct DuckingConfig: Codable {
        var duckLevel: Int = 5
        var rampSteps: Int = 15
        var rampDurationMs: Int = 600
        var duckAppleMusic: Bool = true
        var duckSpotify: Bool = true
        var useMediaKey: Bool = true  // pause/resume browser audio via media key
        // Extra bundle IDs / path substrings treated as media-key clients
        // (the pause toggle is only sent to apps that will claim it —
        // unclaimed presses launch Music). Optional: decode-safe.
        var mediaKeyApps: [String]?
    }

    struct SpeechConfig: Codable {
        var rate: Float = 0.59       // ~213 WPM (0.0=min, 1.0=max)
        var voiceIdentifier: String? // nil = auto-select best English voice
        var pitch: Float?            // reading-voice multiplier, 0.5-2.0 (nil = 1.0)
    }

    struct DisplayConfig: Codable {
        var invertForApps: [String] = []  // bundle IDs, e.g. ["com.apple.iWork.Pages"]
        var invertEnabled: Bool? = false      // app-list inversion — OPT-IN (:config invert on)
        var pdfDark: String? = "auto"         // auto (follow system theme) | on | off
        var autoInvert: Bool? = false         // measure window brightness (Screen Recording)
        var autoInvertThreshold: Int? = 70    // percent brightness that counts as "bright"
        var dockIcon: Bool? = false           // .regular policy: Dock + app switcher + Force Quit
    }
}

enum ConfigLoader {
    private static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/marduk")
    private static let configFile = configDir.appendingPathComponent("config.json")

    static func load() -> MardukConfig {
        let decoder = JSONDecoder()
        guard FileManager.default.fileExists(atPath: configFile.path),
              let data = try? Data(contentsOf: configFile),
              let config = try? decoder.decode(MardukConfig.self, from: data) else {
            let defaultConfig = MardukConfig()
            save(defaultConfig)
            return defaultConfig
        }
        return config
    }

    static func save(_ config: MardukConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            let data = try encoder.encode(config)
            try data.write(to: configFile, options: .atomic)
        } catch {
            fputs("Warning: Could not save config: \(error.localizedDescription)\n", stderr)
        }
    }
}
