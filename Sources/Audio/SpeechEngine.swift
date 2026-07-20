import AVFoundation

/// Wraps AVSpeechSynthesizer with ducking integration.
/// When speech starts, external audio ducks. When speech ends, it restores.
final class SpeechEngine: NSObject, @unchecked Sendable {
    private nonisolated(unsafe) let synthesizer = AVSpeechSynthesizer()
    private let ducker: AudioDucker

    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    var voice: AVSpeechSynthesisVoice?
    var announcementVoice: AVSpeechSynthesisVoice?
    var preprocessor: SpeechPreprocessor.Settings = .default

    /// Called with the character range being spoken (for word-level tracking)
    var onWordBoundary: ((NSRange) -> Void)?

    // The utterance that currently owns the duck state. Delegate callbacks for
    // any other utterance are stale (it was replaced by a newer speak()) and
    // must not unduck, or they would resume media mid-way through the
    // replacement utterance.
    private var currentUtterance: AVSpeechUtterance?

    // Per-utterance completion handlers, fired on finish OR cancel. Keyed by
    // utterance identity so a replaced utterance can never fire a completion
    // that was registered for its successor.
    private var completions: [ObjectIdentifier: () -> Void] = [:]

    // True while a content read (not an announcement) is speaking or paused.
    // Plain stored state, not an AV query — the event-tap callback reads it
    // synchronously to decide whether Space is pause/resume or a normal key.
    private(set) var readActive = false

    init(ducker: AudioDucker) {
        self.ducker = ducker
        super.init()
        synthesizer.delegate = self

        let voices = AVSpeechSynthesisVoice.speechVoices()
        let en = voices.filter { $0.language.hasPrefix("en") }

        // Reading voice: first enhanced English voice (original default)
        if let enhanced = en.first(where: { $0.quality == .enhanced }) {
            voice = enhanced
        } else {
            voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        fputs("[speech] Reading voice: \(voice?.name ?? "default") (\(voice?.language ?? "en"))\n", stderr)

        // Announcement voice: Daniel (en-GB) for status updates
        announcementVoice = en.first(where: { $0.name == "Daniel" && $0.language == "en-GB" })
            ?? en.first(where: { $0.name.contains("Daniel") })
        fputs("[speech] Announcement voice: \(announcementVoice?.name ?? "default") (\(announcementVoice?.language ?? "en"))\n", stderr)
    }

    // MARK: - Public API

    func speak(_ text: String, completion: (() -> Void)? = nil) {
        let processed = SpeechPreprocessor.process(text, settings: preprocessor)
        // Guard sits before stop(): invisible-junk input is a true no-op and
        // doesn't kill an in-progress read. Completion must still fire — the
        // inline CLI blocks on it.
        guard !processed.isEmpty else {
            fputs("[verbalizer] nothing speakable after preprocessing, skipping\n", stderr)
            completion?()
            return
        }
        stop()

        let utterance = AVSpeechUtterance(string: processed)
        utterance.rate = rate
        utterance.voice = voice
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.05
        utterance.postUtteranceDelay = 0.05

        startSpeaking(utterance, completion: completion)
        readActive = true
    }

    /// Speak with distinct announcement voice — status updates only.
    /// `voice:` overrides for a one-off utterance (the ":voices" picker
    /// previews each candidate in its own voice).
    func announce(_ text: String, voice previewVoice: AVSpeechSynthesisVoice? = nil,
                  completion: (() -> Void)? = nil) {
        stop()

        // Fixed internal strings: sanitize only, no symbol verbalization
        let utterance = AVSpeechUtterance(string: SpeechPreprocessor.sanitize(text))
        utterance.rate = 0.50                          // moderate pace
        utterance.voice = previewVoice ?? announcementVoice ?? voice
        utterance.pitchMultiplier = 0.9                // just a touch lower, natural
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.0
        utterance.postUtteranceDelay = 0.0

        startSpeaking(utterance, completion: completion)
        readActive = false
    }

    func speakSSML(_ ssml: String) {
        stop()

        guard let utterance = AVSpeechUtterance(ssmlRepresentation: ssml) else {
            // Fallback to plain text if SSML parsing fails
            let cleaned = ssml.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            speak(cleaned)
            return
        }
        utterance.rate = rate
        utterance.voice = voice

        startSpeaking(utterance, completion: nil)
        readActive = true
    }

    private func startSpeaking(_ utterance: AVSpeechUtterance, completion: (() -> Void)?) {
        if let completion {
            completions[ObjectIdentifier(utterance)] = completion
        }
        currentUtterance = utterance
        ducker.prepareToDuck()
        // Belt and braces against the paused-wedge (see stop())
        if synthesizer.isPaused {
            fputs("[speech] synthesizer was left paused — resuming before speak\n", stderr)
            synthesizer.continueSpeaking()
        }
        synthesizer.speak(utterance)
    }

    func stop() {
        // Un-wedge first: a synthesizer stopped WHILE PAUSED can stay stuck
        // in the paused state, silently queueing every future utterance —
        // the whole engine goes mute until the daemon restarts.
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
        }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .word)
    }

    func resume() {
        synthesizer.continueSpeaking()
    }

    /// Space toggle: pause an active read at a word boundary, resume a
    /// paused one. Media stays ducked/paused across the pause — only the
    /// read's natural end (or a stop) unducks.
    func togglePause() {
        if synthesizer.isPaused {
            fputs("[speech] resumed\n", stderr)
            synthesizer.continueSpeaking()
        } else if synthesizer.isSpeaking {
            fputs("[speech] paused\n", stderr)
            synthesizer.pauseSpeaking(at: .word)
        }
    }

    var isSpeaking: Bool {
        synthesizer.isSpeaking
    }

    var isPaused: Bool {
        synthesizer.isPaused
    }

    /// Adjust rate. 0.0 = min, 1.0 = max. Default is ~0.5.
    func adjustRate(delta: Float) {
        rate = max(AVSpeechUtteranceMinimumSpeechRate,
                   min(AVSpeechUtteranceMaximumSpeechRate, rate + delta))
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechEngine: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        fputs("[speech] didStart fired\n", stderr)
        guard utterance === currentUtterance else { return }
        ducker.duck()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        fputs("[speech] didFinish fired\n", stderr)
        finish(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        fputs("[speech] didCancel fired\n", stderr)
        finish(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        onWordBoundary?(characterRange)
    }

    private func finish(_ utterance: AVSpeechUtterance) {
        // Only the current utterance owns the duck state. A stale didCancel
        // (delivered after speak() already replaced the utterance) skipping
        // unduck is intentional: the replacement re-uses the ducked state and
        // will unduck when it ends.
        if utterance === currentUtterance {
            ducker.unduck()
            currentUtterance = nil
            readActive = false
        }
        if let completion = completions.removeValue(forKey: ObjectIdentifier(utterance)) {
            completion()
        }
    }
}
