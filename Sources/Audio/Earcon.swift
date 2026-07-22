import AVFoundation

/// Generates short synthesized audio cues (earcons).
/// Uses AVAudioPlayer with in-memory WAV data — no engine setup needed.
enum Earcon {
    private static var player: AVAudioPlayer?

    // WAV synthesis is deterministic, and error() fires on every suppressed
    // key in NORMAL mode — cache instead of regenerating PCM per press.
    // Only ever touched from the main thread.
    private static var wavCache: [String: Data] = [:]

    /// Rising two-tone bloop (like Bluetooth connect)
    static func bloopUp() {
        play(frequencies: [500, 800])
    }

    /// Falling two-tone bloop (like Bluetooth disconnect)
    static func bloopDown() {
        play(frequencies: [800, 500])
    }

    /// Rising three-tone sweep — signals climbing "up" to NORMAL (the top
    /// of the INSERT → READING → NORMAL ladder). Low → mid → high, tight and
    /// quick so it reads as a single upward motion. Ends higher than
    /// riseToReading so the destination level is audible.
    static func riseToNormal() {
        play(frequencies: [440, 660, 990], toneDuration: 0.05, gapDuration: 0.0)
    }

    /// Rising sweep for the MIDDLE rung — climbing INSERT → READING (held
    /// Escape reclaiming a still-playing read). Same shape as riseToNormal
    /// but ends a step lower (990 → 784, a whole tone under), so the two
    /// climb destinations are distinguishable by ear.
    static func riseToReading() {
        play(frequencies: [440, 660, 784], toneDuration: 0.05, gapDuration: 0.0)
    }

    /// Falling three-tone sweep — mirror of riseToNormal. Signals dropping
    /// "down" into INSERT (typing-burst rescue). Deliberately not spoken:
    /// speech would duck media and talk over the user mid-typing.
    static func fallToInsert() {
        play(frequencies: [990, 660, 440], toneDuration: 0.05, gapDuration: 0.0)
    }

    /// Sharp, loud buzzer — signals a key that did nothing (e.g. typing in NORMAL mode).
    /// Square wave + hard attack make it abrupt and cutting.
    static func error() {
        play(frequencies: [200], toneDuration: 0.11, gapDuration: 0.0,
             amplitude: 0.6, square: true, fadeDuration: 0.0015)
    }

    private static func play(
        frequencies: [Double],
        toneDuration: Double = 0.07,
        gapDuration: Double = 0.03,
        amplitude: Double = 0.25,
        square: Bool = false,
        fadeDuration: Double = 0.009
    ) {
        let cacheKey = "\(frequencies)|\(toneDuration)|\(gapDuration)|\(amplitude)|\(square)|\(fadeDuration)"
        if let wav = wavCache[cacheKey] {
            playData(wav)
            return
        }

        let sampleRate = 44100
        let toneSamples = Int(Double(sampleRate) * toneDuration)
        let gapSamples = Int(Double(sampleRate) * gapDuration)
        let totalSamples = frequencies.count * toneSamples + max(0, frequencies.count - 1) * gapSamples

        // Generate 16-bit PCM
        var pcm = [Int16](repeating: 0, count: totalSamples)
        var offset = 0
        for (i, freq) in frequencies.enumerated() {
            let fade = max(1, Int(Double(sampleRate) * fadeDuration))
            for s in 0..<toneSamples {
                let t = Double(s) / Double(sampleRate)
                let env = min(Double(s) / Double(fade), Double(toneSamples - 1 - s) / Double(fade), 1.0)
                let raw = sin(2.0 * .pi * freq * t)
                let wave = square ? (raw >= 0 ? 1.0 : -1.0) : raw
                pcm[offset + s] = Int16(wave * amplitude * env * 32767.0)
            }
            offset += toneSamples
            if i < frequencies.count - 1 { offset += gapSamples }
        }

        // Build WAV in memory
        let dataBytes = totalSamples * 2
        var wav = Data(capacity: 44 + dataBytes)

        wav.append(ascii: "RIFF")
        wav.appendLE(UInt32(36 + dataBytes))
        wav.append(ascii: "WAVE")
        wav.append(ascii: "fmt ")
        wav.appendLE(UInt32(16))        // chunk size
        wav.appendLE(UInt16(1))         // PCM format
        wav.appendLE(UInt16(1))         // mono
        wav.appendLE(UInt32(sampleRate))
        wav.appendLE(UInt32(sampleRate * 2)) // byte rate
        wav.appendLE(UInt16(2))         // block align
        wav.appendLE(UInt16(16))        // bits per sample
        wav.append(ascii: "data")
        wav.appendLE(UInt32(dataBytes))
        pcm.withUnsafeBytes { wav.append(contentsOf: $0) }

        wavCache[cacheKey] = wav
        playData(wav)
    }

    private static func playData(_ wav: Data) {
        do {
            player = try AVAudioPlayer(data: wav)
            player?.play()
        } catch {
            fputs("[earcon] \(error)\n", stderr)
        }
    }
}

private extension Data {
    mutating func appendLE(_ v: UInt16) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ v: UInt32) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
    mutating func append(ascii s: String) {
        append(contentsOf: s.utf8)
    }
}
