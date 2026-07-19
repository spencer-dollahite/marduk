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

    // Every field below is Optional: synthesized Codable treats non-Optional
    // keys as REQUIRED (property defaults are ignored on decode), so a
    // hand-written partial block ("keyboard": {"typingRescue": false}) would fail
    // the whole decode — and load() resets a failed decode to defaults,
    // wiping voice/rate. Defaults are applied at the consumption site.
    struct KeyboardConfig: Codable {
        var escapeHoldMs: Int? = 400     // hold Escape this long in INSERT → NORMAL
        var typingBurstMs: Int? = 300    // typing-rescue burst window
        var typingRescue: Bool? = true   // false disables typing rescue
    }

    struct VerbalizerConfig: Codable {
        var level: String? = "most"     // none | some | most | all
        var symbols: [String: String]?  // overrides, e.g. {"*": "asterisk", "->": "maps to", "%": ""}
        var hashes: Bool? = true        // abbreviate hex digests: "md5 ending in 2 7 e"
    }

    struct DuckingConfig: Codable {
        var duckLevel: Int = 5
        var rampSteps: Int = 15
        var rampDurationMs: Int = 600
        var duckAppleMusic: Bool = true
        var duckSpotify: Bool = true
        var useMediaKey: Bool = true  // pause/resume browser audio via media key
    }

    struct SpeechConfig: Codable {
        var rate: Float = 0.59       // ~213 WPM (0.0=min, 1.0=max)
        var voiceIdentifier: String? // nil = auto-select best English voice
    }

    struct DisplayConfig: Codable {
        var invertForApps: [String] = []  // bundle IDs, e.g. ["com.apple.iWork.Pages"]
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
