import AVFoundation

/// Wraps AVSpeechSynthesizer with ducking integration.
/// When speech starts, external audio ducks. When speech ends, it restores.
final class SpeechEngine: NSObject, @unchecked Sendable {
    private nonisolated(unsafe) var synthesizer = AVSpeechSynthesizer()
    private let ducker: AudioDucker

    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    var pitch: Float = 1.0  // reading voice only; announcements/echo keep their own
    var voice: AVSpeechSynthesisVoice?
    var announcementVoice: AVSpeechSynthesisVoice?
    var preprocessor: SpeechPreprocessor.Settings = .default

    /// The frontmost app's bundle ID at read start (KeyboardMonitor's cached
    /// workspace observer) — the system pronunciation dictionary scopes
    /// entries per app. Nil (inline CLI) keeps all-apps entries only.
    var frontmostAppProvider: (() -> String?)?

    // Voice-captured (IPA) pronunciation entries applying to the current
    // read. Applied as utterance ATTRIBUTES over the processed text — never
    // text mutation — so motion/search offsets are untouched and respeak
    // substrings just re-match. Text (respelling) entries are substituted
    // into the raw text in speak() instead.
    private var readIPAEntries: [SystemPronunciations.Entry] = []

    /// Called with the character range being spoken (for word-level tracking)
    var onWordBoundary: ((NSRange) -> Void)?

    // Visual follow hooks (Daemon wires them to KeyboardMonitor):
    /// A paged read landed on a 1-based page (every page jump routes
    /// through speakPage) — Preview turns to it via a synthetic gesture.
    var onPageJump: ((Int) -> Void)?
    /// A new content read replaced readText — stale follow anchors from a
    /// previous web read must be dropped before this read speaks.
    var onNewRead: (() -> Void)?
    /// The read position moved (word boundaries and every respeak/jump).
    /// Cheap to fire; consumers throttle.
    var onPositionChange: ((Int) -> Void)?

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
    private var readPosition = 0 {
        didSet {
            guard readPosition != oldValue else { return }
            onPositionChange?(readPosition)
            // Paged reads: ANY page crossing turns the visual page —
            // explicit jumps land here via respeak, and a read that just
            // flows over a boundary lands here via word boundaries. One
            // tracker, no double-fires.
            if let paged = readPaged {
                let page = pagedWindowFirst + paged.pageIndex(at: readPosition)
                if page != followPageIndex {
                    followPageIndex = page
                    // Synthetic pages have no viewer to follow — the
                    // tracker still advances (page echo, continuation) but
                    // no go-to-page gesture fires.
                    if !pagedSynthetic { onPageJump?(page + 1) }
                }
            }
        }
    }
    // Last page whose visual follow fired (paged reads only)
    private var followPageIndex = -1
    // Page starts when the current read is a paged document (PDF, or huge
    // plain text chunked into synthetic pages) — pages are respeak targets
    // layered on the flat readText. Nil = not paged.
    // readPaged is the current WINDOW; pagedFull is the whole document and
    // pagedWindowFirst maps window page indices to global ones. Jumps
    // outside the window rebuild it (loadPageWindow) — any page of any
    // size document is reachable while preprocessing stays bounded.
    private var readPaged: PagedText?
    private var pagedFull: PagedText?
    private var pagedWindowFirst = 0
    // Synthetic paging (huge plain text chunked into pages): same machinery,
    // but no viewer follows along — go-to-page gestures are suppressed.
    private var pagedSynthetic = false

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

        // Reading voice default: IDENTITY FIRST. Marduk's users are
        // existing AT users who already picked a voice they trust in
        // Spoken Content — familiarity IS intelligibility (field lesson
        // 2026-07), so the system's default voice for the language wins
        // over any quality ranking. The API may return the COMPACT
        // edition of that choice, so upgrade within the same name to the
        // best installed build (Samantha → Samantha Enhanced). No system
        // default at all → enhanced (the battle-tested screen-reader
        // class, crisp at speed) → premium → compact. Premium voices are
        // OFFERED (welcome line, :voices hint, tip), never imposed. An
        // explicit voiceIdentifier in config overrides all of this
        // afterward and is never touched.
        var systemDefault = false
        if let sys = AVSpeechSynthesisVoice(language: "en-US") {
            systemDefault = true
            voice = en.filter { $0.name == sys.name }
                .max(by: { $0.quality.rawValue < $1.quality.rawValue }) ?? sys
        } else {
            voice = en.first(where: { $0.quality == .enhanced })
                ?? en.first(where: { $0.quality == .premium })
                ?? en.first
        }
        let quality = voice?.quality == .premium ? "premium"
            : voice?.quality == .enhanced ? "enhanced" : "default"
        fputs("[speech] Reading voice: \(voice?.name ?? "none") "
            + "(\(voice?.language ?? "en"), \(quality)"
            + "\(systemDefault ? ", system default" : ""))\n", stderr)

        // Announcement voice: Daniel (en-GB) for status updates
        announcementVoice = en.first(where: { $0.name == "Daniel" && $0.language == "en-GB" })
            ?? en.first(where: { $0.name.contains("Daniel") })
        fputs("[speech] Announcement voice: \(announcementVoice?.name ?? "default") (\(announcementVoice?.language ?? "en"))\n", stderr)
    }

    // MARK: - Public API

    func speak(_ text: String, completion: (() -> Void)? = nil) {
        // The user's system pronunciation dictionary, fresh each read so
        // Settings edits apply immediately. Typed entries rewrite the text
        // (before preprocessing — one consistent text for motions, search,
        // and spell); voice-captured IPA entries are held for utterance
        // attributes in makeReadUtterance.
        let pronunciations = SystemPronunciations.relevant(
            SystemPronunciations.fetch(),
            voiceLanguage: voice?.language,
            frontmostBundleID: frontmostAppProvider?())
        readIPAEntries = pronunciations.filter { $0.ipa != nil }
        let substituted = SystemPronunciations.applyText(pronunciations, to: text)
        let processed = SpeechPreprocessor.process(substituted, settings: preprocessor)
        // Guard sits before stop(): invisible-junk input is a true no-op and
        // doesn't kill an in-progress read. Completion must still fire — the
        // inline CLI blocks on it.
        guard !processed.isEmpty else {
            fputs("[verbalizer] nothing speakable after preprocessing, skipping\n", stderr)
            completion?()
            return
        }
        stop()

        onNewRead?()
        readText = processed
        readPaged = nil  // plain read; speakPaged re-sets after this returns
        pagedFull = nil
        pagedSynthetic = false
        readBase = 0
        readPosition = 0
        segmentStartedAt = Date()
        startSpeaking(makeReadUtterance(processed), completion: completion)
        readActive = true
    }

    private func makeReadUtterance(_ text: String) -> AVSpeechUtterance {
        // IPA pronunciation entries ride as attributes so the string — and
        // every boundary offset — stays byte-identical to readText
        let utterance: AVSpeechUtterance
        if let attributed = SystemPronunciations.attributed(text, entries: readIPAEntries) {
            utterance = AVSpeechUtterance(attributedString: attributed)
        } else {
            utterance = AVSpeechUtterance(string: text)
        }
        utterance.rate = rate
        utterance.voice = voice
        utterance.pitchMultiplier = pitch
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
        readPaged = nil
        pagedFull = nil
        pagedSynthetic = false
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
        readPaged = nil
        pagedFull = nil
        pagedSynthetic = false
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

    /// Whether the current read has page structure (PDF or synthetic).
    var isPaged: Bool { readActive && readPaged != nil }

    /// A paged document read: speak a page WINDOW starting at the visible
    /// page (1-based). The full document is retained; page jumps outside
    /// the window rebuild it there, and a window that ends naturally
    /// continues into the next one (didFinish). `synthetic` marks chunked
    /// plain text — same machinery, no viewer gestures.
    func speakPaged(_ paged: PagedText, startPage: Int, synthetic: Bool = false,
                    completion: (() -> Void)? = nil) {
        let (first, window) = paged.window(startingAt: startPage - 1)
        speak(window.text, completion: completion)
        guard readActive else { return }  // empty-after-preprocessing
        pagedFull = paged
        pagedWindowFirst = first
        readPaged = window
        pagedSynthetic = synthetic
        // Preview already SHOWS the start page (the title told us) — seed
        // the tracker so the initial jump doesn't fire a redundant gesture
        followPageIndex = max(0, min(startPage - 1, paged.pageCount - 1))
    }

    /// Rebuild the window at a new global page and keep reading — the
    /// completion carries exactly like respeak's (the read's eventual end
    /// still fires it), and media stays ducked across the swap because the
    /// replaced utterance's didCancel is stale by the time it lands.
    /// False when the new window never started speaking (its text
    /// preprocessed to nothing — whitespace-only PDF pages, stripped
    /// junk): state is left untouched and the caller must not assume a
    /// live read, or a silent capture would strand the keyboard.
    @discardableResult
    private func loadPageWindow(atGlobalPage global: Int) -> Bool {
        guard let full = pagedFull else { return false }
        let synthetic = pagedSynthetic  // speak() clears it — capture first
        let replaced = currentUtterance
        let carried = replaced.flatMap {
            completions.removeValue(forKey: ObjectIdentifier($0))
        }
        let (first, window) = full.window(startingAt: global)
        speak(window.text, completion: carried)
        guard readActive, currentUtterance !== replaced else { return false }
        pagedFull = full          // speak() cleared paged state — restore
        pagedWindowFirst = first
        readPaged = window
        pagedSynthetic = synthetic
        // Seed BEHIND the arrival page: unlike speakPaged's start (Preview
        // already shows it), the viewer has NOT turned to a rebuilt
        // window's page — the first word boundary must fire the gesture.
        followPageIndex = global - 1
        return true
    }

    /// Ctrl+F / Ctrl+B: step pages (vim count semantics — step may be ±N).
    /// False when the read isn't paged or the edge stops the whole step.
    @discardableResult
    func jumpPage(step: Int) -> Bool {
        stopEcho()
        guard readActive, let window = readPaged, let full = pagedFull else { return false }
        let current = pagedWindowFirst
            + window.pageIndex(at: step < 0 ? backAnchor : readPosition)
        let target = max(0, min(current + step, full.pageCount - 1))
        guard target != current else { return false }
        return speakPage(globalIndex: target)
    }

    /// 12G / bare G on a paged read: absolute page, 1-based, clamped —
    /// GLOBAL page numbers, any page of any size document.
    @discardableResult
    func jumpToPage(_ number: Int) -> Bool {
        stopEcho()
        guard readActive, readPaged != nil, let full = pagedFull else { return false }
        let target = max(0, min(number - 1, full.pageCount - 1))
        return speakPage(globalIndex: target)
    }

    var pageCount: Int { pagedFull?.pageCount ?? 0 }

    /// Ctrl+G — where am I: percent through the whole document (vim's
    /// file-info ruler), plus page info on paged reads. Speaks over the
    /// read on the echo channel like the page echo; never pauses or
    /// moves the read. Works on any active read, speaking or paused.
    @discardableResult
    func speakPosition() -> Bool {
        stopEcho()
        guard readActive, let text = readText else { return false }
        if let window = readPaged, let full = pagedFull {
            let page = pagedWindowFirst + window.pageIndex(at: readPosition)
            // Window-local processed offset against raw page starts — the
            // same accepted drift as the page tracker; invisible at
            // whole-percent granularity.
            let global = full.pageStarts[pagedWindowFirst] + readPosition
            let pct = ReadNavigator.percent(global, of: full.utf16Length)
            fputs("[speech] position: page \(page + 1) of \(full.pageCount), "
                + "\(pct)%\n", stderr)
            echo("page \(page + 1) of \(full.pageCount), \(pct) percent")
        } else {
            let pct = ReadNavigator.percent(readPosition, of: text.utf16.count)
            fputs("[speech] position: \(pct)%\n", stderr)
            echo("\(pct) percent")
        }
        return true
    }

    /// {count}% — vim percent navigation: respeak from N percent through
    /// the document (clamped 1-100). Page-granular on paged reads (the
    /// page containing that point, echoed like any page jump); word-
    /// snapped respeak on plain reads.
    @discardableResult
    func jumpToPercent(_ percent: Int) -> Bool {
        stopEcho()
        guard readActive, let text = readText else { return false }
        let pct = max(1, min(100, percent))
        if let full = pagedFull {
            let target = full.pageIndex(at: pct * full.utf16Length / 100)
            return speakPage(globalIndex: target)
        }
        let ns = text as NSString
        guard ns.length > 0 else { return false }
        let raw = min(ns.length * pct / 100, ns.length - 1)
        respeak(from: ReadNavigator.wordStart(in: text, at: raw))
        return true
    }

    private func speakPage(globalIndex: Int) -> Bool {
        guard let window = readPaged, let full = pagedFull else { return false }
        fputs("[speech] page \(globalIndex + 1) of \(full.pageCount)\n", stderr)
        // The echo overlaps the respeak's first beat on purpose — it's the
        // distinct voice, and a pause-announce-resume dance costs latency
        echo("page \(globalIndex + 1)")
        let local = globalIndex - pagedWindowFirst
        if window.pageStarts.indices.contains(local) {
            respeak(from: window.pageStarts[local])  // tracker fires onPageJump
        } else {
            loadPageWindow(atGlobalPage: globalIndex)
        }
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

    /// Pointer hover speech: short element labels in the READING voice at
    /// the user's rate and pitch — the whole point is that hover sounds
    /// exactly like reads. Rides the echo synthesizer so an active read
    /// is never disturbed; a new label cuts the previous one.
    func hover(_ text: String) {
        let sanitized = SpeechPreprocessor.sanitize(text)
        guard !sanitized.isEmpty else { return }
        stopEcho()
        let utterance = AVSpeechUtterance(string: sanitized)
        utterance.rate = rate
        utterance.voice = voice
        utterance.pitchMultiplier = pitch
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
            synthesizer.pauseSpeaking(at: .immediate)
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

    // Speech-health watchdog: an utterance the synthesizer ACCEPTS but
    // never STARTS (zero didStart — field: media paused, text delivered,
    // total silence) means the synthesis service wedged. One automatic
    // recovery per wedge: rebuild the synthesizer and respeak the read
    // from its start; a second failure beeps and logs the manual cure.
    private var sawStartForCurrent = false
    private var wedgeRebuilt = false

    private func startSpeaking(_ utterance: AVSpeechUtterance, completion: (() -> Void)?) {
        if let completion {
            completions[ObjectIdentifier(utterance)] = completion
        }
        currentUtterance = utterance
        sawStartForCurrent = false
        ducker.prepareToDuck()
        // Belt and braces against the paused-wedge (see stop())
        if synthesizer.isPaused {
            fputs("[speech] synthesizer was left paused — resuming before speak\n", stderr)
            synthesizer.continueSpeaking()
        }
        synthesizer.speak(utterance)
        // Duck NOW, not only on didStart: duck() is idempotent (already-
        // ducked targets skip), and delegate delivery can lapse when the
        // synthesizer is wedge-adjacent — media must still pause even if
        // didStart never arrives (field-diagnosed: reads audible over
        // music with zero didStart lines in the log).
        ducker.duck()

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, utterance === self.currentUtterance,
                  !self.sawStartForCurrent else { return }
            fputs("[speech] synthesizer accepted the utterance but never "
                + "started it (4s)\n", stderr)
            if !self.wedgeRebuilt {
                self.wedgeRebuilt = true
                fputs("[speech] rebuilding the synthesizer and retrying\n", stderr)
                self.synthesizer.stopSpeaking(at: .immediate)
                self.synthesizer = AVSpeechSynthesizer()
                self.synthesizer.delegate = self
                if self.readText != nil {
                    self.respeak(from: self.readBase)
                }
            } else {
                Earcon.error()
                fputs("[speech] synthesizer still silent after rebuild — "
                    + "try 'marduk restart', or killall speechsynthesisd, "
                    + "or a reboot\n", stderr)
            }
        }
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
        synthesizer.pauseSpeaking(at: .immediate)
    }

    func resume() {
        synthesizer.continueSpeaking()
    }

    /// Space toggle: pause an active read, resume a paused one. Media
    /// stays ducked/paused across the pause — only the read's natural end
    /// (or a stop) unducks. PAUSES ARE .immediate EVERYWHERE, never
    /// .word: a word-boundary pause is DEFERRED, and if a stop or a new
    /// speak lands in that window (Escape tap-then-hold, tap-then-r,
    /// Space-then-read — routine gestures now), the pending pause applies
    /// to a stopped synthesizer and wedges it — delegate callbacks stop
    /// arriving, didStart never fires, ducking (didStart-driven) dies,
    /// and the engine eventually goes fully mute until restart.
    /// Field-diagnosed 2026-07-21 from the user's log.
    func togglePause() {
        stopEcho() // resuming must not compete with a running spell-out
        if synthesizer.isPaused {
            fputs("[speech] resumed\n", stderr)
            synthesizer.continueSpeaking()
        } else if synthesizer.isSpeaking {
            fputs("[speech] paused\n", stderr)
            synthesizer.pauseSpeaking(at: .immediate)
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
        sawStartForCurrent = true
        wedgeRebuilt = false  // healthy again — future wedges get a fresh retry
        ducker.duck()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        fputs("[speech] didFinish fired\n", stderr)
        // Window continuation: a paged read whose WINDOW ended naturally
        // keeps going — load the next window instead of tearing down.
        // Only didFinish continues (didCancel is a user stop); the check
        // must precede finish(), while currentUtterance still points at
        // the finishing utterance so loadPageWindow carries its completion
        // and the skipped teardown keeps media ducked across the boundary.
        if utterance === currentUtterance, let window = readPaged,
           let full = pagedFull,
           let next = full.nextWindowStart(afterWindowFirst: pagedWindowFirst,
                                           windowPageCount: window.pageCount) {
            fputs("[speech] window ended — continuing at page \(next + 1) "
                + "of \(full.pageCount)\n", stderr)
            if loadPageWindow(atGlobalPage: next) { return }
            // Next window preprocessed to nothing — end the read normally
            // rather than strand a silent capture.
        }
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
            readPaged = nil
            pagedFull = nil
            pagedSynthetic = false
            readIPAEntries = []
        }
        if let completion = completions.removeValue(forKey: ObjectIdentifier(utterance)) {
            completion()
        }
    }
}
