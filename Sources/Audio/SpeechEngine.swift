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
    // The didSet drives the keyboard's READING capture — fired synchronously
    // (speak() runs on main, delegate callbacks land on main), so the tap
    // never sees a read without its capture. Consecutive reads and respeak
    // jumps stay true throughout: no spurious exit/re-enter events.
    private(set) var readActive = false {
        didSet { if readActive != oldValue { onReadActiveChange?(readActive) } }
    }
    var onReadActiveChange: ((Bool) -> Void)?

    // Read-motion state: the FULL processed text of the current read plus
    // where the voice is in it. AVSpeechSynthesizer cannot seek, so a jump
    // stops the current utterance and re-speaks a substring — readBase maps
    // the replacement utterance's boundary callbacks (relative to the
    // substring) back into full-text coordinates. All UTF-16 offsets,
    // matching willSpeakRangeOfSpeechString. nil readText = not navigable
    // (announcements, SSML).
    private var readText: String?
    private var readBase = 0
    private var readPosition = 0

    // Back-motion anchor: at fast speech rates the boundary callbacks race
    // ahead of comprehension — by the time a `b` lands, readPosition is
    // several words past what the user absorbed, and repeated back-jumps
    // tread water (each respeak blurts a few words before the next press).
    // Within this window of a segment starting (read start or any jump),
    // back motions anchor at the segment's BEGINNING (readBase), so a
    // second `b` reliably lands one unit before the last target. After the
    // window, the user has genuinely listened — anchor at the live position.
    // Forward motions always use the live position.
    private var segmentStartedAt = Date.distantPast
    private let backAnchorWindow: TimeInterval = 1.5
    private var backAnchor: Int {
        Date().timeIntervalSince(segmentStartedAt) < backAnchorWindow
            ? readBase : readPosition
    }

    // Dedicated synthesizer for search-entry echo: announce() stop()s the
    // main synthesizer, which would destroy the paused read mid-search.
    // A second synthesizer speaks over it without touching read state,
    // completions, or ducking.
    private nonisolated(unsafe) let echoSynthesizer = AVSpeechSynthesizer()

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

        readText = processed
        readBase = 0
        readPosition = 0
        segmentStartedAt = Date()
        startSpeaking(makeReadUtterance(processed), completion: completion)
        readActive = true
    }

    private func makeReadUtterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate
        utterance.voice = voice
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.05
        utterance.postUtteranceDelay = 0.05
        return utterance
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
        readText = nil
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
        readText = nil // SSML positions don't map to plain text — no motions
    }

    // MARK: - Read motions (vim-style navigation within the current read)

    /// Jump within the current read. A count applies the motion repeatedly
    /// (vim `3(`), stopping early at an edge — as far as possible beats a
    /// no-op. Returns false only when nothing moved at all (already at the
    /// edge, or nothing navigable) — the caller buzzes so silence isn't
    /// ambiguous. Works while paused: the respeak auto-resumes from the
    /// target, which doubles as feedback.
    @discardableResult
    func jump(_ unit: ReadUnit, direction: ReadDirection, count: Int = 1) -> Bool {
        stopEcho()
        guard readActive, let text = readText else { return false }
        var position = direction == .back ? backAnchor : readPosition
        for _ in 0..<max(1, count) {
            let next = ReadNavigator.target(in: text, from: position,
                                            unit: unit, direction: direction)
            if next == position { break }
            position = next
        }
        guard position != readPosition else { return false }
        respeak(from: position)
        return true
    }

    /// Absolute-offset jump (the search handler computes the target).
    func jumpTo(offset: Int) {
        stopEcho()
        guard readActive, readText != nil else { return }
        respeak(from: offset)
    }

    /// gg (.back → the very beginning) / G (.forward → the last paragraph).
    @discardableResult
    func jumpToEdge(_ direction: ReadDirection) -> Bool {
        stopEcho()
        guard readActive, let text = readText else { return false }
        let target = direction == .back ? 0 : ReadNavigator.endTarget(in: text)
        guard target != readPosition else { return false }
        respeak(from: target)
        return true
    }

    /// Vim f/F + char: jump to the word containing the next/previous
    /// occurrence. False = no match in that direction (caller buzzes).
    /// Back-finds use the back anchor, same as the back motions.
    @discardableResult
    func findChar(_ char: Character, direction: ReadDirection) -> Bool {
        stopEcho()
        guard readActive, let text = readText else { return false }
        let from = direction == .back ? backAnchor : readPosition
        guard let hit = ReadNavigator.findChar(in: text, from: from,
                                               char: char, direction: direction) else {
            return false
        }
        respeak(from: ReadNavigator.wordStart(in: text, at: hit))
        return true
    }

    /// Vim 0: restart the current line. False at the line's start (or when
    /// nothing is navigable) — the caller buzzes.
    @discardableResult
    func jumpToLineStart() -> Bool {
        stopEcho()
        guard readActive, let text = readText else { return false }
        let target = ReadNavigator.lineStart(in: text, at: backAnchor)
        guard target != readPosition else { return false }
        respeak(from: target)
        return true
    }

    /// The current read's full text and voice position, for search.
    var readSnapshot: (text: String, position: Int)? {
        guard readActive, let text = readText else { return nil }
        return (text, readPosition)
    }

    /// Re-speak the retained read text from a new offset. Reuses the normal
    /// startSpeaking flow: the replaced utterance's didCancel is stale by the
    /// time it lands (currentUtterance already points at the successor), so
    /// nothing unducks — media stays paused across the jump with no blip.
    /// The old utterance's completion moves to the new one, so the read's
    /// eventual end still fires it (the inline CLI blocks on it, the
    /// tutorial listens for it). No re-preprocessing: readText already IS
    /// the processed string, and boundary offsets must keep matching it.
    private func respeak(from target: Int) {
        guard let text = readText else { return }
        let ns = text as NSString
        let clamped = max(0, min(target, ns.length))
        let remainder = ns.substring(from: clamped)
        guard !remainder.isEmpty else { return }

        let carried = currentUtterance.flatMap {
            completions.removeValue(forKey: ObjectIdentifier($0))
        }
        stop()
        readBase = clamped
        readPosition = clamped
        segmentStartedAt = Date()
        startSpeaking(makeReadUtterance(remainder), completion: carried)
        readActive = true
    }

    /// Speak a short cue (search-entry keystroke echo, spell-out) over a
    /// paused read WITHOUT touching it — announce() would stop() the read.
    /// No ducking, no completion, no read state; a new echo cuts off the
    /// previous one.
    func echo(_ text: String) {
        let sanitized = SpeechPreprocessor.sanitize(text)
        guard !sanitized.isEmpty else { return }
        stopEcho()
        let utterance = AVSpeechUtterance(string: sanitized)
        utterance.rate = 0.55
        utterance.voice = announcementVoice ?? voice
        utterance.pitchMultiplier = 0.9
        utterance.volume = 1.0
        echoSynthesizer.speak(utterance)
    }

    /// A running spell-out (a sentence can take half a minute) must never
    /// talk over navigation or a resumed read — every jump/pause entry
    /// point cuts it.
    private func stopEcho() {
        if echoSynthesizer.isSpeaking {
            echoSynthesizer.stopSpeaking(at: .immediate)
        }
    }

    // MARK: - Spell-out (z word / Z sentence, reading capture)

    private var lastSpellText = ""
    private var lastSpellAnchor = -1
    private var lastSpellTime = Date.distantPast

    /// Spell the word/sentence containing the current position over the
    /// (auto-paused) read, via the echo synthesizer. A second word-spell
    /// on the same target within a few seconds goes NATO-phonetic —
    /// "Charlie, Alpha, Tango" — the b-versus-d disambiguator. Returns
    /// false when there's nothing to spell (caller buzzes).
    @discardableResult
    func spell(_ unit: ReadUnit) -> Bool {
        guard readActive, let text = readText else { return false }
        if synthesizer.isSpeaking, !synthesizer.isPaused {
            synthesizer.pauseSpeaking(at: .word)
        }
        let anchor = backAnchor
        guard let span = ReadNavigator.unitText(in: text, at: anchor, unit: unit),
              !span.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let nato = unit == .word && span == lastSpellText
            && anchor == lastSpellAnchor
            && Date().timeIntervalSince(lastSpellTime) < 6
        lastSpellText = span
        lastSpellAnchor = anchor
        lastSpellTime = Date()
        fputs("[speech] spell \(unit == .word ? "word" : "sentence") "
            + "(\(span.count) chars\(nato ? ", phonetic" : ""))\n", stderr)
        echo(Self.spellOut(span, nato: nato))
        return true
    }

    /// "Cat" → "capital c, a, t" (phonetic: "capital Charlie, Alpha,
    /// Tango"); spaces say "space"; digits and punctuation speak as
    /// themselves. Pure — unit-tested.
    static func spellOut(_ text: String, nato: Bool) -> String {
        var parts: [String] = []
        for ch in text {
            if ch == " " || ch == "\n" || ch == "\t" {
                parts.append("space")
                continue
            }
            let lower = ch.lowercased()
            let base = nato ? (Self.natoAlphabet[lower] ?? lower) : lower
            parts.append(ch.isUppercase ? "capital \(base)" : base)
        }
        return parts.joined(separator: ", ")
    }

    private static let natoAlphabet: [String: String] = [
        "a": "Alpha", "b": "Bravo", "c": "Charlie", "d": "Delta",
        "e": "Echo", "f": "Foxtrot", "g": "Golf", "h": "Hotel",
        "i": "India", "j": "Juliett", "k": "Kilo", "l": "Lima",
        "m": "Mike", "n": "November", "o": "Oscar", "p": "Papa",
        "q": "Quebec", "r": "Romeo", "s": "Sierra", "t": "Tango",
        "u": "Uniform", "v": "Victor", "w": "Whiskey", "x": "X-ray",
        "y": "Yankee", "z": "Zulu",
    ]

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
        stopEcho() // a running spell-out dies with the read
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
        stopEcho() // resuming must not compete with a running spell-out
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
        // Track the voice's position for read motions — full-text coordinates
        // via readBase. Stale utterances (just replaced by a jump) must not
        // drag the position back to where the old utterance was.
        if utterance === currentUtterance, readText != nil {
            readPosition = readBase + characterRange.location
        }
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
            readText = nil
        }
        if let completion = completions.removeValue(forKey: ObjectIdentifier(utterance)) {
            completion()
        }
    }
}
