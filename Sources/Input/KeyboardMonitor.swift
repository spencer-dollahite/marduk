import Foundation
import AppKit
import ApplicationServices
import CoreAudio

/// Monitors global keyboard events via CGEventTap.
/// Vim-style modal: starts in NORMAL mode (commands active),
/// `i` enters INSERT mode (keys pass through). In INSERT, a *tapped* Escape
/// belongs to the app (vim, Claude Code, dialogs) and is delivered on key
/// release; a *held* Escape (>= escapeHoldThreshold) returns to NORMAL and
/// the app never sees it.
/// Ctrl+Option+M toggles Marduk on/off entirely.
final class KeyboardMonitor {
    typealias SpeakHandler = (String) -> Void
    typealias StopHandler = () -> Void
    typealias AnnounceHandler = (String) -> Void
    typealias UpdateHandler = () -> Void

    enum Mode { case normal, insert, visual, visualLine, command }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapWatchdog: DispatchSourceTimer?
    private var tapRetry: DispatchSourceTimer?
    // FAIL-OPEN: when Marduk's main thread can't process keys promptly,
    // the correct assistive behavior is to stop intercepting entirely —
    // the user keeps a fully working raw keyboard while Marduk degrades.
    // Field incident: a silent auto-update's swift build starved the main
    // thread; withheld burst keys were never released, macOS oscillated
    // the tap, and the machine's keyboard was half-dead until a reboot.
    // failOpen is touched from main AND the sentinel queue — lock it.
    private let failOpenLock = NSLock()
    private var failOpenReasons = Set<String>()
    private var lastMainBeat = Date()
    private var latencySentinel: DispatchSourceTimer?
    private var onSpeak: SpeakHandler?
    private var onStop: StopHandler?
    private var onAnnounce: AnnounceHandler?
    private var onUpdate: UpdateHandler?
    private var isSpeaking: () -> Bool = { false }
    private var isReadActive: () -> Bool = { false }
    private var isReadPaused: () -> Bool = { false }
    private var onPauseToggle: (() -> Void)?
    private var stopped = false

    private(set) var isEnabled = true {
        didSet { if isEnabled != oldValue { onEnabledChange?(isEnabled) } }
    }
    private(set) var mode: Mode = .normal {
        didSet { if mode != oldValue { onModeChange?(mode) } }
    }

    // Mode/enabled observers (fired synchronously from the tap callback —
    // handlers must dispatch their own work and never block)
    var onModeChange: ((Mode) -> Void)?
    var onEnabledChange: ((Bool) -> Void)?

    // COMMAND mode (":"). Buffer is main-thread-only like all tap state.
    // Callbacks are dispatched to main; the palette/daemon react there.
    var onCommandSubmit: ((String) -> Void)?
    // (buffer, canAutoAccept) — auto-accept must only fire on typed chars,
    // never on deletions, or removing an auto-added space would re-add it.
    var onCommandChange: ((String, Bool) -> Void)?
    var onCommandTab: (() -> Void)?
    var onCommandSelect: ((Int) -> Void)?
    var onCommandHelp: (() -> Void)?    // "?" — speak options, even when none
    var onCommandIdle: (() -> Void)?    // typing pause — speak options if any
    var onUpdateCheck: (() -> Void)?    // single u — check + speak release notes
    private var commandIdleTimer: DispatchWorkItem?
    var typingEchoEnabled = false    // speak chars typed in INSERT
    var commandEchoEnabled = true    // speak chars typed after ":"
    var speedKeysEnabled = false     // Option+Up/Down nudge speech rate (NORMAL/VISUAL)
    var toggleEarconEnabled = false  // Ctrl+Option+M bloops instead of speaking
    var onRateChange: ((Float) -> Void)?  // signed rate delta from the speed keys

    // Read motions (default ON, `:config readmotions off` disables): vim
    // navigation inside an active read — b/w/h/l word, (/) sentence, j/k
    // line, {/} paragraph, digits count, / and ? search. While enabled,
    // an active read CAPTURES the keyboard from any mode (READING is a
    // real mode: i and held Escape are the only exits); with the setting
    // off, every key keeps its normal behavior. State is main-thread-only
    // like all tap state.
    var readMotionsEnabled = false {
        didSet {
            // Turned off mid-read (socket-side :config): drop the capture,
            // or the motions would keep firing with the feature off
            if !readMotionsEnabled { readingCapture = false }
        }
    }
    // True while a read owns the keyboard. Set by readStateChanged (the
    // engine's readActive didSet, synchronous on main) — the tap callback
    // reads it directly. The underlying `mode` is left untouched while
    // capturing; only the explicit exits (i, Escape) change it, so a read
    // that ends naturally returns the user exactly where they were.
    // onReadingChange fires on actual flips, sometimes synchronously from
    // the tap callback — handlers must only dispatch, never block (same
    // contract as onModeChange/onEnabledChange). Drives the overlay's
    // purple READING color.
    var onReadingChange: ((Bool) -> Void)?
    private(set) var readingCapture = false {
        didSet { if readingCapture != oldValue { onReadingChange?(readingCapture) } }
    }
    var onReadJump: ((ReadUnit, ReadDirection, Int) -> Void)?
    var onReadSearch: ((String, ReadDirection) -> Void)?
    var onReadSearchBegin: (() -> Void)?    // pause the read while typing
    var onReadSearchCancel: (() -> Void)?   // Escape/empty — resume in place
    var onReadSearchEcho: ((String) -> Void)?  // echo keystrokes OVER the paused read
    private var readSearchDirection: ReadDirection?  // non-nil = entry state active
    private var readSearchBuffer = ""
    private var readMotionCount = 0          // pending vim count, e.g. 3(
    private var pendingReadG = false         // first g of gg seen (no timeout — vim style)
    var onReadJumpEdge: ((ReadDirection) -> Void)?   // gg (.back) / G (.forward)
    var onReadLineStart: (() -> Void)?               // bare 0 — restart the line
    var onReadSpell: ((ReadUnit) -> Void)?           // z word / Z sentence
    // `.` repeats the last motion (vim). Repeating a search re-hunts from
    // the new position — vim's n by another name, without the Firefox-n
    // collision. Persists across reads, like vim's dot across edits.
    private enum ReadAction {
        case jump(ReadUnit, ReadDirection, Int)
        case edge(ReadDirection)
        case search(String, ReadDirection)
        case find(Character, ReadDirection)
        case pageStep(Int)
    }
    var onReadPageStep: ((Int) -> Void)?      // Ctrl+F/Ctrl+B, ±count pages
    var onReadPageAbsolute: ((Int) -> Void)?  // 12G — page twelve
    var onReadPercent: ((Int) -> Void)?       // 50% — jump to N percent
    var onReadPosition: (() -> Void)?         // Ctrl+G — where am I
    var onSpeakPaged: ((PagedText, Int) -> Void)?  // PDF read (paged, 1-based start)
    // Full-document read: complete text + UTF-16 start offset. The daemon
    // decides plain vs synthetic-paged (huge text chunks into pages, so
    // the whole document is reachable). Anchored web reads stay on onSpeak
    // — their line→anchor scroll mapping assumes unwindowed text.
    var onSpeakDocument: ((String, Int) -> Void)?
    private var lastReadAction: ReadAction?
    var onReadFind: ((Character, ReadDirection) -> Void)?  // f/F + char
    private var pendingReadFind: ReadDirection?  // f pressed, awaiting the target char

    /// Drop every half-entered read-motion state (count, pending gg,
    /// armed find) — the exits, toggles, and read end all need this.
    private func resetReadMotionState() {
        readMotionCount = 0
        pendingReadG = false
        pendingReadFind = nil
    }

    // Dialog-focus question (armed by the daemon when a dialog
    // announcement carries the a/o/n/s consent tail). Main-thread-only
    // like all tap state; answered/expired/superseded → the closure is
    // released, and with it the daemon's retained dialog target.
    private var pendingDialogAnswer: ((Character) -> Void)?
    private var dialogQuestionTimeout: DispatchWorkItem?
    private static let dialogAnswerKeys: [Int64: Character] =
        [0: "a", 31: "o", 45: "n", 1: "s"]
    private static let dialogQuestionWindow: TimeInterval = 20

    /// Arm the a/o/n/s capture for one question. Main thread only. A new
    /// question replaces an armed one; the timeout bounds how long the
    /// answer keys shadow their NORMAL meanings (s = hover, Firefox n).
    func armDialogQuestion(onAnswer: @escaping (Character) -> Void) {
        cancelDialogQuestion()
        pendingDialogAnswer = onAnswer
        let work = DispatchWorkItem { [weak self] in self?.cancelDialogQuestion() }
        dialogQuestionTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dialogQuestionWindow,
                                      execute: work)
    }

    func cancelDialogQuestion() {
        dialogQuestionTimeout?.cancel()
        dialogQuestionTimeout = nil
        pendingDialogAnswer = nil
    }

    // Firefox Reader narration handoff (`n` in NORMAL while Firefox is
    // frontmost). true = Marduk stops its own speech and holds media
    // paused while Firefox's Narrate reads; false = release. State is
    // main-thread-only like all tap state.
    var onNarrate: ((Bool) -> Void)?
    private var narrationActive = false
    // Cached by a workspace observer so the tap callback can gate the `n`
    // command on the frontmost app without querying anything in-callback
    private var frontmostBundleID =
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    /// The cached frontmost bundle ID for consumers outside the tap (the
    /// speech engine scopes system pronunciation entries per app).
    var frontmostApp: String? { frontmostBundleID.isEmpty ? nil : frontmostBundleID }
    private var workspaceObserver: NSObjectProtocol?
    private var isFirefoxFrontmost: Bool { frontmostBundleID == "org.mozilla.firefox" }
    private var commandBuffer = ""
    // After an auto-expand ("posi" → "config position "), the user may still
    // be typing the rest of the word — those chars are absorbed, not appended.
    private var commandAbsorbTail: [Character] = []
    private var didSpeakColonHint = false

    // `s` — Marduk-native pointer hover speech (HoverSpeech, daemon-owned):
    // the reading voice at the user's rate/pitch, replacing the macOS
    // hover feature (whose separately-configured voice never matched)
    var onHoverToggle: (() -> Void)?

    // Typing-burst rescue (NORMAL mode). Unmodified letter keyDowns are
    // withheld briefly instead of executing immediately; a quick burst that
    // contains a non-command letter means the user forgot they're in NORMAL
    // and started typing — switch to INSERT and replay the withheld keys so
    // nothing is lost and no command fires. All of this state is
    // main-thread-only (the tap callback and the decision timer both run on
    // the main runloop), same argument as the Escape tap/hold state below.
    private var burstBuffer: [CGEvent] = []   // copies of withheld keyDowns, in order
    private var burstTimer: DispatchWorkItem?
    private var isFlushingBurst = false        // redispatch in progress — bypass the hook
    var typingBurstThreshold: TimeInterval = 0.3
    var typingRescueEnabled = true

    // Replay-in-flight rollover: real keys arriving between the INSERT
    // decision and the async replay post must be swallowed and appended,
    // or the app would receive them before the replayed burst (the same
    // ordering hazard the Escape rollover solves). A non-empty queue IS the
    // replay-pending state — no separate flag that could desync.
    private var replayQueue: [CGEvent] = []    // marker-tagged, ready to post

    // Tap/hold Escape in INSERT mode. The keyDown is withheld until we know
    // which gesture it is: keyUp before the threshold = tap (deliver a
    // synthetic Escape to the app), timer firing first = hold (→ NORMAL,
    // swallow everything including the trailing keyUp). Both the tap callback
    // and the timer run on the main thread, so this state is race-free.
    private var pendingEscapeHold: DispatchWorkItem?
    private var escapeHoldFired = false
    var escapeHoldThreshold: TimeInterval = 0.4

    // Tap/hold Escape in READING capture: tap = pause/resume (same as
    // Space), hold = stop the read and return to NORMAL. Same threshold
    // and the same escapeHoldFired keyUp-swallow as the INSERT machinery;
    // the two pendings are mutually exclusive (different modes).
    private var pendingReadingEscape: DispatchWorkItem?

    // Visual mode count prefix (e.g. V3j)
    private var pendingCount: Int = 0

    // Whether the current visual session actually extended a selection.
    // Exiting visual mode collapses via a synthetic Right-arrow in non-AX
    // apps; posting that when nothing was ever selected would move the
    // user's caret for no reason (v then Escape must be a no-op).
    private var visualDidExtendSelection = false

    // Suppress autorepeats of the `i` keypress that entered INSERT mode
    private var suppressInsertEntryRepeat = false

    // Marker to identify our own synthetic key events so the tap ignores them
    private static let syntheticMarker: Int64 = 0x4D52444B // "MRDK"

    // macOS keycodes for digit keys 0-9
    private static let digitKeyCodes: [Int64: Int] = [
        29: 0, 18: 1, 19: 2, 20: 3, 21: 4,
        23: 5, 22: 6, 26: 7, 28: 8, 25: 9
    ]

    // AX-based visual selection state (for Terminal and apps where Shift+Arrow doesn't select)
    private struct VisualAXState {
        let element: AXUIElement
        let text: NSString  // UTF-16 indexed to match AX API
        var anchor: Int     // character offset where visual mode started
        var cursor: Int     // current end of selection
    }
    private var visualAXState: VisualAXState?

    func start(
        onSpeak: @escaping SpeakHandler,
        onStop: @escaping StopHandler,
        onAnnounce: @escaping AnnounceHandler,
        onUpdate: @escaping UpdateHandler,
        isSpeaking: @escaping () -> Bool,
        isReadActive: @escaping () -> Bool = { false },
        isReadPaused: @escaping () -> Bool = { false },
        onPauseToggle: (() -> Void)? = nil
    ) {
        self.onSpeak = onSpeak
        self.onStop = onStop
        self.onAnnounce = onAnnounce
        self.onUpdate = onUpdate
        self.isSpeaking = isSpeaking
        self.isReadActive = isReadActive
        self.isReadPaused = isReadPaused
        self.onPauseToggle = onPauseToggle

        // Keep the frontmost-app cache warm for the `n` narration gate
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            self?.frontmostBundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.bundleIdentifier ?? ""
        }

        if createTap() {
            fputs("[keyboard] NORMAL mode (Ctrl+Option+M to disable, i for INSERT)\n", stderr)
        } else {
            // A dead tap is invisible to a screen-reader user — say it out
            // loud (speech needs no Accessibility permission) and keep
            // retrying so a grant takes effect without a daemon restart.
            fputs("[keyboard] Failed to create event tap — check Accessibility permission\n", stderr)
            onAnnounce("Keyboard commands unavailable. Grant Marduk Accessibility permission in System Settings.")
            scheduleTapRetry()
        }
    }

    private func createTap() -> Bool {
        // keyUp is needed to distinguish a tapped Escape from a held one
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: KeyboardMonitor.eventCallback,
            userInfo: refcon
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Self-heal: macOS silently disables event taps it deems unresponsive.
        // We re-enable on the tapDisabledByTimeout event, but that notification
        // only arrives with the NEXT event and can be missed entirely — leaving
        // Marduk deaf until restart. Poll as a backstop.
        let watchdog = DispatchSource.makeTimerSource(queue: .main)
        watchdog.schedule(deadline: .now() + 5, repeating: 5)
        watchdog.setEventHandler { [weak self] in
            guard let self, !self.stopped, let tap = self.eventTap else { return }
            self.failOpenLock.lock()
            let open = !self.failOpenReasons.isEmpty
            self.failOpenLock.unlock()
            if !open, !CGEvent.tapIsEnabled(tap: tap) {
                fputs("[keyboard] event tap was disabled — re-enabling\n", stderr)
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        watchdog.resume()
        tapWatchdog = watchdog
        startLatencySentinel()
        return true
    }

    // MARK: - Fail-open (never half-strangle the keyboard)

    /// Reasons stack: the sentinel and the updater can each hold the tap
    /// open independently; it re-arms only when every reason clears.
    /// Callable from any thread — CGEvent.tapEnable is thread-safe, and
    /// dispatching to a congested main thread would defeat the point.
    func beginFailOpen(reason: String) {
        failOpenLock.lock()
        let wasOpen = !failOpenReasons.isEmpty
        failOpenReasons.insert(reason)
        failOpenLock.unlock()
        guard !wasOpen, let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        fputs("[keyboard] FAIL-OPEN (\(reason)) — keys pass through raw\n", stderr)
    }

    func endFailOpen(reason: String) {
        failOpenLock.lock()
        failOpenReasons.remove(reason)
        let nowClear = failOpenReasons.isEmpty
        failOpenLock.unlock()
        guard nowClear, !stopped, let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        fputs("[keyboard] fail-open ended (\(reason)) — tap re-armed\n", stderr)
    }

    /// A background heartbeat measures MAIN QUEUE latency directly: a
    /// marker is dispatched to main every beat; if the previous marker
    /// hasn't run after the threshold, main is congested and the tap
    /// fails open until markers flow again. Runs entirely off-main.
    private func startLatencySentinel() {
        guard latencySentinel == nil else { return }
        failOpenLock.lock(); lastMainBeat = Date(); failOpenLock.unlock()
        let sentinel = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.marduk.latency", qos: .userInitiated))
        sentinel.schedule(deadline: .now() + 2, repeating: 1.5)
        sentinel.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.failOpenLock.lock()
                self.lastMainBeat = Date()
                self.failOpenLock.unlock()
            }
            self.failOpenLock.lock()
            let lag = Date().timeIntervalSince(self.lastMainBeat)
            let tripped = self.failOpenReasons.contains("main-thread congestion")
            self.failOpenLock.unlock()
            if lag > 4, !tripped {
                fputs("[keyboard] main thread lagging \(String(format: "%.1f", lag))s\n",
                      stderr)
                self.beginFailOpen(reason: "main-thread congestion")
            } else if lag < 1, tripped {
                self.endFailOpen(reason: "main-thread congestion")
            }
        }
        sentinel.resume()
        latencySentinel = sentinel
    }

    private func scheduleTapRetry() {
        let retry = DispatchSource.makeTimerSource(queue: .main)
        retry.schedule(deadline: .now() + 10, repeating: 10)
        retry.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            if self.createTap() {
                self.tapRetry?.cancel()
                self.tapRetry = nil
                fputs("[keyboard] Event tap created after permission grant\n", stderr)
                self.onAnnounce?("Keyboard commands active.")
            }
        }
        retry.resume()
        tapRetry = retry
    }

    func stop() {
        stopped = true
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
        tapWatchdog?.cancel()
        tapWatchdog = nil
        latencySentinel?.cancel()
        latencySentinel = nil
        tapRetry?.cancel()
        tapRetry = nil
        commandBuffer = ""
        commandIdleTimer?.cancel()
        readSearchDirection = nil
        readSearchBuffer = ""
        resetReadMotionState()
        readingCapture = false
        pendingReadingEscape?.cancel()
        pendingReadingEscape = nil
        discardBurstAndReplay()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Event Tap Callback

    private static let eventCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon = refcon else { return Unmanaged.passRetained(event) }
        let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
        return monitor.handleEvent(type: type, event: event)
    }

    // Keep callback lightweight — dispatch all side effects to main queue
    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if stopped { return pass }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }

        guard type == .keyDown || type == .keyUp else { return pass }

        // Pass through our own synthetic key events (visual mode selection,
        // tapped-Escape delivery)
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return pass
        }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)

        // keyUps only matter for the Escape tap/hold state machine
        if type == .keyUp {
            if keycode == 53 { return handleEscapeKeyUp(pass: pass) }
            return pass
        }

        let flags = event.flags
        let hasOption = flags.contains(.maskAlternate)
        let hasControl = flags.contains(.maskControl)
        let hasCommand = flags.contains(.maskCommand)
        // Key autorepeat must not re-trigger one-shot/toggle commands: a held
        // Option+Escape's repeat event would see isSpeaking == true and stop
        // the very read it just started ("speech randomly cuts out").
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        // === Always-active shortcuts ===

        // Option+Escape — speak selection / stop speech. A PAUSED read is
        // silent but still reports isSpeaking — before Escape-tap-pause
        // existed that state was rare; now it's routine, and letting it
        // swallow the press ("stop" nothing audible) made chained selection
        // reads feel completely broken. Paused = the user obviously wants
        // the new selection: clear the old read AND read in one press.
        // Audibly speaking = the press means "silence that", unchanged.
        if keycode == 53, hasOption {
            if isAutorepeat { return nil }
            DispatchQueue.main.async { [self] in
                if isSpeaking() {
                    let paused = isReadPaused()
                    onStop?()
                    if paused {
                        Self.readSelection { [self] text in onSpeakDocument?(text, 0) }
                    }
                } else {
                    Self.readSelection { [self] text in onSpeakDocument?(text, 0) }
                }
            }
            return nil
        }

        // Ctrl+Option+M (keycode 46) — toggle Marduk on/off
        if keycode == 46, hasControl, hasOption, !hasCommand {
            if isAutorepeat { return nil }
            isEnabled.toggle()
            if isEnabled { mode = .normal }
            // Never carry tap/hold state across a toggle — a half-decided
            // Escape must not fire (or swallow a keyUp) after re-enable
            pendingEscapeHold?.cancel()
            pendingEscapeHold = nil
            pendingReadingEscape?.cancel()
            pendingReadingEscape = nil
            escapeHoldFired = false
            // Same for a half-decided typing burst: discard, don't flush
            discardBurstAndReplay()
            // And a half-typed ":" command
            commandBuffer = ""
            commandIdleTimer?.cancel()
            // And any read-motion state (a paused search must not eat keys
            // after re-enable; the daemon side resumes nothing — the read
            // itself was stopped by the toggle path or died with it)
            readSearchDirection = nil
            readSearchBuffer = ""
            resetReadMotionState()
            readingCapture = false
            // And an armed dialog-focus question (releases its AX target)
            cancelDialogQuestion()
            let state = isEnabled ? "ON (NORMAL)" : "OFF"
            fputs("[keyboard] Marduk \(state)\n", stderr)
            let word = isEnabled ? "Systems engaged" : "Systems disengaged"
            let on = isEnabled
            DispatchQueue.main.async { [self] in
                // Disabling mid-narration must not leave media stuck paused
                if narrationActive {
                    narrationActive = false
                    postKey(keycode: 45)
                    onNarrate?(false)
                }
                if toggleEarconEnabled {
                    if on { Earcon.bloopUp() } else { Earcon.bloopDown() }
                } else {
                    onAnnounce?(word)
                }
            }
            return nil
        }

        // === Marduk disabled: pass everything through ===
        guard isEnabled else { return pass }

        // READING-Escape rollover: another key while the reading Escape is
        // still withheld resolves it as a tap (pause), then the new key
        // takes its normal route — the pause dispatch lands on main before
        // any motion the key produces, so ordering holds (a fast Esc-then-(
        // pauses, then the jump's respeak resumes from the target).
        if pendingReadingEscape != nil, keycode != 53 {
            pendingReadingEscape?.cancel()
            pendingReadingEscape = nil
            DispatchQueue.main.async { [self] in onPauseToggle?() }
        }

        // Rollover: another key while a tapped Escape is still withheld means
        // the user typed on (fast Esc then j in vim). Letting this event pass
        // while the Escape is re-posted asynchronously would deliver them out
        // of order (vim would insert a stray "j"). Swallow it and re-post
        // both synthetically, in order. Pending state implies INSERT mode, so
        // this key was app-bound anyway (always-active shortcuts, which the
        // marker would bypass, were already handled above).
        if pendingEscapeHold != nil, keycode != 53 {
            pendingEscapeHold?.cancel()
            pendingEscapeHold = nil
            if let rolled = event.copy() {
                rolled.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
                DispatchQueue.main.async { [self] in
                    postKey(keycode: 53)
                    rolled.post(tap: .cghidEventTap)
                }
                return nil
            }
            // Copy failed: at least deliver the Escape, let this event pass
            DispatchQueue.main.async { [self] in postKey(keycode: 53) }
        }

        // Replay rollover: while a typing-rescue replay is queued but not
        // yet posted, letting a real key through would deliver it before
        // the replayed burst (fast "sho" would type "osh"). Swallow it and
        // append to the replay so everything lands in order. This window is
        // a single runloop turn right after the NORMAL→INSERT flip, so a
        // real Escape caught here is typed rather than tap/hold-detected —
        // acceptable. Flush redispatches manage their own ordering.
        if !replayQueue.isEmpty, !isFlushingBurst, let queued = event.copy() {
            enqueueReplay(queued)
            return nil
        }

        // === READ-SEARCH entry: typing a / or ? query over a paused read ===
        // A lightweight sibling of COMMAND mode. The read was paused on
        // entry; echo goes through the dedicated echo path (announce()
        // would stop() the paused read). MUST be checked before the Space
        // pause block: Space is a LITERAL query char here, and the paused
        // read still reports readActive — Space would otherwise resume it
        // mid-query.
        if let direction = readSearchDirection {
            // Read died under us (Option+Escape, daemon restart): abandon
            // the entry state and let the key take its normal route.
            if !isReadActive() {
                readSearchDirection = nil
                readSearchBuffer = ""
            } else {
                if hasCommand || hasControl { return pass }   // app shortcuts untouched
                if isAutorepeat, keycode != 51 { return nil } // only Delete repeats

                switch keycode {
                case 36: // Return — run the search (empty buffer = cancel)
                    let query = readSearchBuffer
                    readSearchDirection = nil
                    readSearchBuffer = ""
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        DispatchQueue.main.async { [self] in onReadSearchCancel?() }
                    } else {
                        lastReadAction = .search(query, direction)
                        // Length only — the query is user content and the
                        // log gets pasted into public issues
                        fputs("[keyboard] read search "
                            + "\(direction == .forward ? "/" : "?") "
                            + "(\(query.count) chars)\n", stderr)
                        DispatchQueue.main.async { [self] in
                            onReadSearch?(query, direction)
                        }
                    }
                    return nil

                case 53: // Escape — cancel, resume the read where it paused
                    readSearchDirection = nil
                    readSearchBuffer = ""
                    fputs("[keyboard] read search cancelled\n", stderr)
                    DispatchQueue.main.async { [self] in onReadSearchCancel?() }
                    return nil

                case 51: // Delete — edit; empty buffer backs out entirely
                    if let removed = readSearchBuffer.popLast() {
                        let spoken = removed == " " ? "space" : String(removed)
                        DispatchQueue.main.async { [self] in
                            if commandEchoEnabled { onReadSearchEcho?("\(spoken) deleted") }
                        }
                    } else {
                        readSearchDirection = nil
                        DispatchQueue.main.async { [self] in onReadSearchCancel?() }
                    }
                    return nil

                default:
                    if hasOption { return pass }  // zoom shortcuts ride on Option
                    if let ch = Self.commandKeyChars[keycode] {
                        readSearchBuffer.append(ch)
                        let spoken = ch == " " ? "space" : String(ch)
                        DispatchQueue.main.async { [self] in
                            if commandEchoEnabled { onReadSearchEcho?(spoken) }
                        }
                        return nil
                    }
                    if Self.typingPunctuationKeys.contains(keycode) {
                        DispatchQueue.main.async { Earcon.error() }
                        return nil
                    }
                    return pass  // F-keys, media keys — not query input
                }
            }
        }

        // === Space: pause/resume an active read (NORMAL/VISUAL only) ===
        // Only while a content read is speaking or paused — announcements
        // never capture Space, and otherwise it types/passes as normal.
        // INSERT means typing: Space is always a real space there, even
        // mid-read. A typing-rescue burst in flight means the user is
        // typing, so Space stays typing there too. Escape (NORMAL) cancels
        // a paused read — a paused synthesizer still counts as speaking —
        // which frees Space back to normal. isReadActive is plain stored
        // state on the speech engine, safe to read in the tap callback.
        if keycode == 49, mode != .insert, mode != .command,
           !hasCommand, !hasControl, !hasOption,
           !flags.contains(.maskShift), burstBuffer.isEmpty, isReadActive() {
            if isAutorepeat { return nil }
            DispatchQueue.main.async { [self] in onPauseToggle?() }
            return nil
        }

        // === READING capture (readmotions on): the read owns the keyboard ===
        // Engaged from ANY mode when a read starts (readStateChanged) —
        // reading is a real mode, not a NORMAL overlay: a read fired from
        // INSERT used to let ( and gg type straight over the selection.
        // b/w step words, (/) sentences, {/} paragraphs, digits build a
        // count (3( = back three), gg/G edges, . repeats, / and ? search,
        // Space pauses. i and Escape are the ONLY exits (both stop the
        // read); every other typing-shaped key buzzes instead of leaking
        // into the app. Cmd/Ctrl/Option combos and non-typing keys
        // (arrows, F-keys, media) still pass. Motions deliberately ALLOW
        // autorepeat — holding ( glides back sentence by sentence; the
        // engine recomputes from the live position each time. A typing
        // burst in flight predates the read — typing intent wins
        // (declareTyping drops the capture).
        if readingCapture, !isReadActive() {
            readingCapture = false  // engine state is the truth; heal drift
        }
        // Ctrl+F / Ctrl+B — vim page scroll, the capture-only exception to
        // the Ctrl-passthrough rule, and only here: during a captured read
        // the app receives no keys anyway, so the carve-out steals nothing.
        // Counts apply (3 Ctrl+F = three pages, vim semantics); autorepeat
        // allowed like the motions; buzzes via the daemon on unpaged
        // reads. Every other Ctrl combo still passes through everywhere.
        if readingCapture, hasControl, !hasCommand, !hasOption,
           burstBuffer.isEmpty, keycode == 3 || keycode == 11 {
            let count = max(1, readMotionCount)
            readMotionCount = 0
            let step = keycode == 3 ? count : -count
            lastReadAction = .pageStep(step)
            DispatchQueue.main.async { [self] in onReadPageStep?(step) }
            return nil
        }
        // Ctrl+G — vim's file-info: where am I? Same capture-only carve-
        // out as Ctrl+F/B. One-shot; consumes a pending count (count
        // Ctrl+G is vim's full-path variant — no audio meaning).
        if readingCapture, hasControl, !hasCommand, !hasOption,
           burstBuffer.isEmpty, keycode == 5 {
            if isAutorepeat { return nil }
            readMotionCount = 0
            pendingReadG = false
            DispatchQueue.main.async { [self] in onReadPosition?() }
            return nil
        }
        if readingCapture, !hasCommand, !hasControl, !hasOption,
           burstBuffer.isEmpty {
            let hasShift = flags.contains(.maskShift)

            // Armed f/F: the NEXT typing key is the find target — checked
            // first so any char works, even ones with motion meanings
            // (f-then-( finds a paren). Non-typing keys (Escape, arrows)
            // cancel silently and act normally, vim-style.
            if let direction = pendingReadFind {
                if isAutorepeat { return nil }
                pendingReadFind = nil
                if let ch = Self.commandKeyChars[keycode] {
                    // commandKeyChars is a-z 0-9 space: uppercased() is
                    // always a single scalar here
                    let target = hasShift ? Character(ch.uppercased()) : ch
                    lastReadAction = .find(target, direction)
                    DispatchQueue.main.async { [self] in
                        onReadFind?(target, direction)
                    }
                    return nil
                }
            }

            if keycode == 3 { // f / F — arm char-find forward / back
                if isAutorepeat { return nil }
                readMotionCount = 0
                pendingReadG = false
                pendingReadFind = hasShift ? .back : .forward
                return nil
            }

            if keycode == 49, !flags.contains(.maskShift) { // Space — pause/resume
                if isAutorepeat { return nil }
                DispatchQueue.main.async { [self] in onPauseToggle?() }
                return nil
            }

            if keycode == 34 { // i — type WHILE the read keeps talking
                // (user-redesigned: the old exit also stopped the read, but
                // "take notes while listening" is a legitimate mode of
                // being human). The capture drops so keys reach the app;
                // the read plays on as background audio. Held Escape climbs
                // BACK into the capture (see the INSERT hold path); Option+
                // Escape stops the audio from anywhere.
                if isAutorepeat { return nil }
                readingCapture = false
                resetReadMotionState()
                mode = .insert
                suppressInsertEntryRepeat = true
                fputs("[keyboard] READING → INSERT (read continues)\n", stderr)
                DispatchQueue.main.async { Earcon.fallToInsert() }
                return nil
            }

            if keycode == 53 { // Escape — tap pauses/resumes, hold exits
                if isAutorepeat { return nil }
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.pendingReadingEscape = nil
                    guard self.readingCapture else { return }
                    self.escapeHoldFired = true
                    self.readingCapture = false
                    self.resetReadMotionState()
                    self.mode = .normal
                    fputs("[keyboard] READING escape held → NORMAL\n", stderr)
                    self.onStop?()
                    Earcon.riseToNormal()
                }
                pendingReadingEscape?.cancel() // never stack two
                pendingReadingEscape = work
                DispatchQueue.main.asyncAfter(deadline: .now() + escapeHoldThreshold,
                                              execute: work)
                return nil
            }

            if keycode == 44 { // / or ? — search entry
                if isAutorepeat { return nil }
                readSearchDirection = hasShift ? .back : .forward
                readSearchBuffer = ""
                resetReadMotionState()
                fputs("[keyboard] read search entry (\(hasShift ? "?" : "/"))\n", stderr)
                let word = hasShift ? "search back" : "search"
                DispatchQueue.main.async { [self] in
                    onReadSearchBegin?()
                    if commandEchoEnabled { onReadSearchEcho?(word) }
                }
                return nil
            }

            // gg — back to the very beginning; G — the last paragraph
            // (vim's first/last line, scaled to listening). A lone g arms
            // the pair, vim-style with no timeout; any other key breaks it.
            if keycode == 5 {
                if isAutorepeat { return nil }
                if hasShift { // G — end of the read; with a count, page N (12G)
                    pendingReadG = false
                    let count = readMotionCount
                    readMotionCount = 0
                    if count > 0 {
                        DispatchQueue.main.async { [self] in onReadPageAbsolute?(count) }
                    } else {
                        lastReadAction = .edge(.forward)
                        DispatchQueue.main.async { [self] in onReadJumpEdge?(.forward) }
                    }
                } else if pendingReadG { // gg
                    pendingReadG = false
                    readMotionCount = 0
                    lastReadAction = .edge(.back)
                    DispatchQueue.main.async { [self] in onReadJumpEdge?(.back) }
                } else {
                    pendingReadG = true
                }
                return nil
            }
            pendingReadG = false  // any non-g key breaks a pending gg

            // r — abandon this read and read what's under the pointer
            // instead; R — abandon it and read the focused document from
            // the caret to the end (both work speaking or paused; the
            // replacement read keeps media ducked and the capture engaged)
            if keycode == 15 {
                if isAutorepeat { return nil }
                readMotionCount = 0
                if hasShift {
                    fputs("[keyboard] READING R → document read\n", stderr)
                    readDocumentFromCaret()
                } else {
                    fputs("[keyboard] READING r → new read\n", stderr)
                    readAtPointer()
                }
                return nil
            }

            // z / Z — spell the current word / sentence over the paused
            // read (vim's own spell commands live under z). A second z on
            // the same word within a few seconds spells it phonetically —
            // Charlie, Alpha, Tango.
            if keycode == 6 {
                if isAutorepeat { return nil }
                readMotionCount = 0
                let unit: ReadUnit = hasShift ? .sentence : .word
                DispatchQueue.main.async { [self] in onReadSpell?(unit) }
                return nil
            }

            // Digits accumulate a count. Bare 0 never starts one (vim: 0
            // is a motion, not a count starter) — it only joins after 3,
            // 30…; on its own it restarts the current line below.
            if !hasShift, let digit = Self.digitKeyCodes[keycode],
               digit != 0 || readMotionCount > 0 {
                readMotionCount = min(readMotionCount * 10 + digit, 999)
                return nil
            }

            // Bare 0 — vim line start: restart the current line
            if !hasShift, keycode == 29 {
                DispatchQueue.main.async { [self] in onReadLineStart?() }
                return nil
            }

            // {count}% — vim percent-of-file navigation: 50% respeaks
            // from halfway through the document. Bare % stays vim-honest
            // (match-paren has no audio meaning) and buzzes.
            if hasShift, keycode == 23 {
                if isAutorepeat { return nil }
                let count = readMotionCount
                readMotionCount = 0
                if count > 0 {
                    DispatchQueue.main.async { [self] in onReadPercent?(count) }
                } else {
                    DispatchQueue.main.async { Earcon.error() }
                }
                return nil
            }

            // . — repeat the last motion; a pending count overrides a
            // jump's recorded one (3. = the same motion, three times).
            // Autorepeat allowed: holding . keeps stepping, like the
            // motions themselves.
            if keycode == 47, !hasShift {
                guard let action = lastReadAction else {
                    readMotionCount = 0
                    DispatchQueue.main.async { Earcon.error() }
                    return nil
                }
                let pending = readMotionCount
                readMotionCount = 0
                switch action {
                case .jump(let unit, let direction, let recorded):
                    let n = pending > 0 ? pending : recorded
                    lastReadAction = .jump(unit, direction, n)
                    DispatchQueue.main.async { [self] in onReadJump?(unit, direction, n) }
                case .edge(let direction):
                    DispatchQueue.main.async { [self] in onReadJumpEdge?(direction) }
                case .search(let query, let direction):
                    DispatchQueue.main.async { [self] in onReadSearch?(query, direction) }
                case .find(let char, let direction):
                    DispatchQueue.main.async { [self] in onReadFind?(char, direction) }
                case .pageStep(let step):
                    DispatchQueue.main.async { [self] in onReadPageStep?(step) }
                }
                return nil
            }

            var jump: (ReadUnit, ReadDirection)?
            if hasShift {
                switch keycode {
                case 25: jump = (.sentence, .back)     // (
                case 29: jump = (.sentence, .forward)  // )
                case 33: jump = (.paragraph, .back)    // {
                case 30: jump = (.paragraph, .forward) // }
                default: break
                }
            } else {
                switch keycode {
                case 11: jump = (.word, .back)         // b
                case 13: jump = (.word, .forward)      // w
                case 4:  jump = (.word, .back)         // h — hjkl cluster:
                case 37: jump = (.word, .forward)      // l   h/l word,
                case 38: jump = (.line, .forward)      // j   j/k line
                case 40: jump = (.line, .back)         // k
                default: break
                }
            }
            if let (unit, direction) = jump {
                let count = max(1, readMotionCount)
                readMotionCount = 0
                lastReadAction = .jump(unit, direction, count)
                DispatchQueue.main.async { [self] in
                    onReadJump?(unit, direction, count)
                }
                return nil
            }
            // Everything else typing-shaped buzzes — reading owns the
            // keyboard, and a silently swallowed key would read as a dead
            // keyboard. Covers letters, shifted digits, punctuation,
            // Return, Tab, Delete. Non-typing keys — arrows, F-keys,
            // media, Naga button codes — pass through untouched.
            if Self.alphaKeyCodes.contains(keycode) || keycode == 40 // K
                || Self.digitKeyCodes[keycode] != nil
                || Self.typingPunctuationKeys.contains(keycode)
                || keycode == 36 || keycode == 48 || keycode == 51 {
                readMotionCount = 0
                if !isAutorepeat {
                    DispatchQueue.main.async { Earcon.error() }
                }
                return nil
            }
            return pass
        }

        // === INSERT-mode n over a Firefox Reader document ===
        // The key PASSES THROUGH untouched — it IS Narrate's play/pause —
        // but Marduk reacts around it: duck + hold on start, release on
        // the next n. The AX context check runs async on main and only
        // matches focus inside an about:reader web area, so text boxes
        // and the URL bar keep typing their n's; mid-narration typing in
        // some other Firefox field stays typing too (end the handoff
        // from NORMAL, or with the n that stops Narrate in the reader).
        if mode == .insert, keycode == 45, !isAutorepeat, isFirefoxFrontmost,
           !hasOption, !flags.contains(.maskShift) {
            DispatchQueue.main.async { [self] in
                guard Self.narrationContext() else { return }
                narrationActive.toggle()
                fputs("[keyboard] narration \(narrationActive ? "handoff" : "off") (INSERT)\n", stderr)
                onNarrate?(narrationActive)
            }
            return pass
        }

        // === Option+Up/Down: live speech rate (opt-in, NORMAL/VISUAL) ===
        // No autorepeat guard on purpose — holding the key keeps nudging.
        // INSERT and COMMAND are excluded: apps own Option+arrows there
        // (editor move-line), and command mode arrows drive the palette.
        // Shift excluded too — Option+Shift+arrows is text selection.
        if speedKeysEnabled, keycode == 126 || keycode == 125,
           mode != .insert, mode != .command,
           hasOption, !hasCommand, !hasControl, !flags.contains(.maskShift) {
            let delta: Float = (keycode == 126 ? 10.0 : -10.0) / 360.0
            DispatchQueue.main.async { [self] in onRateChange?(delta) }
            return nil
        }

        // === COMMAND mode: ":" line editor, driven entirely by the tap ===
        // The palette panel (if enabled) is display-only — it renders this
        // buffer; no window ever takes focus. Echo goes through onAnnounce.
        if mode == .command {
            // Ctrl+N / Ctrl+P — vim's completion-menu next/previous,
            // synonyms for Down/Up. The second Ctrl carve-out (after
            // reading's Ctrl+F/B), COMMAND-only: the user is driving
            // Marduk's command line, and passing these through would move
            // the app's cursor (macOS emacs bindings) mid-command anyway.
            // Autorepeat allowed, like the arrows.
            if hasControl, !hasCommand, !hasOption,
               keycode == 45 || keycode == 35 {
                let delta = keycode == 45 ? 1 : -1  // n down, p up
                DispatchQueue.main.async { [self] in onCommandSelect?(delta) }
                return nil
            }
            if hasCommand || hasControl { return pass }   // app shortcuts untouched
            if isAutorepeat, keycode != 51, keycode != 125, keycode != 126 {
                return nil                                 // only Delete/arrows repeat
            }

            switch keycode {
            case 36: // Return — submit (empty buffer = cancel)
                let cmd = commandBuffer
                if cmd.hasPrefix("/") || cmd.hasPrefix("voices") {
                    // Fuzzy search and the voice picker: Enter accepts the
                    // selection. Stay in COMMAND mode — the daemon either
                    // executes (and ends the mode) or expands the buffer
                    // for further typing. ("voices" can't collide with
                    // another command — no name is a prefix of another.)
                    fputs("[keyboard] : \(cmd) (selection accept)\n", stderr)
                    DispatchQueue.main.async { [self] in onCommandSubmit?(cmd) }
                    return nil
                }
                commandBuffer = ""
                commandAbsorbTail = []
                commandIdleTimer?.cancel()
                mode = .normal
                if cmd.trimmingCharacters(in: .whitespaces).isEmpty {
                    DispatchQueue.main.async { Earcon.riseToNormal() }
                } else {
                    fputs("[keyboard] : \(cmd)\n", stderr)
                    DispatchQueue.main.async { [self] in onCommandSubmit?(cmd) }
                }
                return nil

            case 53: // Escape — cancel
                commandBuffer = ""
                commandAbsorbTail = []
                commandIdleTimer?.cancel()
                mode = .normal
                fputs("[keyboard] command cancelled → NORMAL\n", stderr)
                DispatchQueue.main.async { Earcon.riseToNormal() }
                return nil

            case 51: // Delete — edit; on an empty buffer, back out entirely
                commandAbsorbTail = []
                if let removed = commandBuffer.popLast() {
                    let buffer = commandBuffer
                    scheduleCommandIdle()
                    let spoken = removed == " " ? "space" : String(removed)
                    DispatchQueue.main.async { [self] in
                        if commandEchoEnabled { onAnnounce?("\(spoken) deleted") }
                        onCommandChange?(buffer, false)
                    }
                } else {
                    commandIdleTimer?.cancel()
                    mode = .normal
                    DispatchQueue.main.async { Earcon.riseToNormal() }
                }
                return nil

            case 48: // Tab — autocomplete to the palette's selected candidate
                scheduleCommandIdle()
                DispatchQueue.main.async { [self] in onCommandTab?() }
                return nil

            case 126, 125: // Up/Down — move the palette selection
                let delta = keycode == 126 ? -1 : 1
                DispatchQueue.main.async { [self] in onCommandSelect?(delta) }
                return nil

            case 44 where flags.contains(.maskShift): // "?" — speak options now
                DispatchQueue.main.async { [self] in onCommandHelp?() }
                return nil

            case 44: // "/" on an empty buffer — fuzzy search over everything
                if commandBuffer.isEmpty {
                    commandBuffer = "/"
                    scheduleCommandIdle()
                    DispatchQueue.main.async { [self] in
                        if commandEchoEnabled { onAnnounce?("search") }
                        onCommandChange?("/", false)
                    }
                } else {
                    DispatchQueue.main.async { Earcon.error() }
                }
                return nil

            default:
                // Option combos are system/app shortcuts (the user's zoom
                // keys ride on Option) — never command input. Pass them.
                if hasOption { return pass }
                if let ch = Self.commandKeyChars[keycode] {
                    // Absorb the tail of a word the auto-expand already
                    // completed; a mismatch ends the absorption.
                    if let expected = commandAbsorbTail.first, ch == expected {
                        commandAbsorbTail.removeFirst()
                        scheduleCommandIdle()
                        return nil
                    }
                    commandAbsorbTail = []
                    // Collapse double spaces (slow typing after an expansion)
                    if ch == " ", commandBuffer.hasSuffix(" ") { return nil }
                    commandBuffer.append(ch)
                    let buffer = commandBuffer
                    scheduleCommandIdle()
                    let spoken = ch == " " ? "space" : String(ch)
                    DispatchQueue.main.async { [self] in
                        if commandEchoEnabled { onAnnounce?(spoken) }
                        onCommandChange?(buffer, true)
                    }
                    return nil
                }
                // Typing-shaped keys (punctuation) buzz — they'd otherwise
                // leak into the app mid-command. Anything else (F-keys,
                // keypad, media keys, zoom shortcuts on custom codes)
                // passes through untouched.
                if Self.typingPunctuationKeys.contains(keycode) {
                    fputs("[keyboard] command mode rejected keycode \(keycode)\n", stderr)
                    DispatchQueue.main.async { Earcon.error() }
                    return nil
                }
                return pass
            }
        }

        // === INSERT mode: only intercept bare Escape (tap/hold) ===
        if mode == .insert {
            if keycode == 53 {
                // Modified Escape (Cmd/Ctrl/Shift) is an app shortcut — pass.
                // Option+Escape was already handled above.
                if hasCommand || hasControl || flags.contains(.maskShift) {
                    return pass
                }
                // Withhold the press until tap-vs-hold is decided. Autorepeats
                // must not leak into the app meanwhile.
                if isAutorepeat { return nil }
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.pendingEscapeHold = nil
                    self.escapeHoldFired = true
                    // Leave typing — and when a read is still playing, the
                    // read reclaims the keyboard first: hold Escape climbs
                    // INSERT → READING → NORMAL, one level per hold
                    if self.readMotionsEnabled, self.isEnabled,
                       self.isReadActive() {
                        self.readingCapture = true
                        fputs("[keyboard] escape held → READING (read reclaimed)\n",
                              stderr)
                        Earcon.riseToNormal()
                        return
                    }
                    self.mode = .normal
                    fputs("[keyboard] escape held → NORMAL\n", stderr)
                    Earcon.riseToNormal()
                }
                pendingEscapeHold?.cancel() // shouldn't happen, but never stack two
                pendingEscapeHold = work
                DispatchQueue.main.asyncAfter(deadline: .now() + escapeHoldThreshold, execute: work)
                return nil
            }
            // Swallow autorepeats of the `i` press that entered INSERT —
            // holding i would otherwise type "iii…" once the mode flips.
            // Any fresh (non-repeat) keypress ends the suppression, so a
            // deliberate held `i` typed later still repeats normally.
            if isAutorepeat, keycode == 34, suppressInsertEntryRepeat {
                return nil
            }
            suppressInsertEntryRepeat = false
            // Optional typing echo (classic screen-reader behavior, off by
            // default): speak the key, never consume it.
            if typingEchoEnabled, !isAutorepeat, !hasCommand, !hasControl, !hasOption,
               let ch = Self.commandKeyChars[keycode] {
                let spoken = ch == " " ? "space" : String(ch)
                DispatchQueue.main.async { [self] in onAnnounce?(spoken) }
            }
            return pass
        }

        // === VISUAL modes: hjkl extends selection, r reads, Escape exits ===
        // All AX/CGEvent work is dispatched off the tap callback: AX calls are
        // synchronous IPC to the target app (up to seconds if it's busy), and
        // a slow callback gets the tap disabled by macOS — which leaks
        // suppressed keys straight into the app. Main-queue ordering keeps the
        // dispatched blocks in keypress order.
        if mode == .visual || mode == .visualLine {
            if hasCommand || hasControl { return pass }

            // Exit/read are one-shot: a held key's autorepeat must not
            // re-trigger them. Motions (hjkl, G, digits) may repeat.
            if isAutorepeat, keycode == 53 || keycode == 9 || keycode == 15 {
                return nil
            }

            switch keycode {
            case 53, 9: // Escape or v/V — exit visual mode, collapse selection
                mode = .normal
                pendingCount = 0
                DispatchQueue.main.async { [self] in
                    collapseVisualSelection()
                    // Audible exit — the rising sweep that always means
                    // "back in NORMAL". (`r` skips it: the read that follows
                    // is its own feedback.)
                    Earcon.riseToNormal()
                }
                fputs("[keyboard] → NORMAL\n", stderr)
                return nil

            case 15: // r — read selection, exit to normal
                mode = .normal
                pendingCount = 0
                DispatchQueue.main.async { [self] in
                    visualAXState = nil
                    Self.readSelection { [self] text in onSpeakDocument?(text, 0) }
                }
                return nil

            case 4: // h — extend selection left
                extendSelection(.left, arrowKeycode: 123)
                return nil

            case 38: // j — extend selection down
                extendSelection(.down, arrowKeycode: 125)
                return nil

            case 40: // k — extend selection up
                extendSelection(.up, arrowKeycode: 126)
                return nil

            case 37: // l — extend selection right
                extendSelection(.right, arrowKeycode: 124)
                return nil

            case 5 where flags.contains(.maskShift): // G — select to end of text
                pendingCount = 0
                visualDidExtendSelection = true
                DispatchQueue.main.async { [self] in
                    if visualAXState != nil {
                        axMotion(.toEnd, count: 1)
                    } else {
                        postKey(keycode: 125, shift: true, command: true)
                    }
                }
                return nil

            default:
                if let digit = Self.digitKeyCodes[keycode] {
                    pendingCount = pendingCount * 10 + digit
                    return nil
                }
                return nil // suppress everything else
            }
        }

        // === NORMAL mode ===

        // Always pass through Cmd and Ctrl combos (system shortcuts like Cmd+C)
        if hasCommand || hasControl {
            return pass
        }

        // Typing-burst rescue: letters are withheld briefly to tell fast
        // typing (→ INSERT + replay) from deliberate commands. Flush
        // redispatches re-enter handleEvent and must reach the real
        // command dispatch below, hence the isFlushingBurst bypass.
        if typingRescueEnabled, !isFlushingBurst,
           let verdict = burstIntercept(event: event, keycode: keycode, isAutorepeat: isAutorepeat) {
            switch verdict {
            case .swallow: return nil
            case .pass(let result): return result
            }
        }

        // Armed dialog question: a/o/n/s answer it; any other key means
        // the user moved on — disarm silently and let the key act normally
        // (vim pendingReadG style). Sits AFTER the burst layer on purpose:
        // rescue-withheld letters only re-enter via the flush, and a burst
        // that resolved to typing replays in INSERT where this never runs —
        // a burst-resolved keystroke can never answer a consent question
        // (the double-u field lesson).
        if pendingDialogAnswer != nil {
            if let answer = Self.dialogAnswerKeys[keycode],
               !flags.contains(.maskShift) {
                if isAutorepeat { return nil }
                let respond = pendingDialogAnswer
                cancelDialogQuestion()
                fputs("[keyboard] dialog question answered: \(answer)\n", stderr)
                DispatchQueue.main.async { respond?(answer) }
                return nil
            }
            cancelDialogQuestion()  // disarm; the key keeps its meaning
        }

        // One-shot commands must not re-fire on key autorepeat: a held `i`
        // would otherwise type "iii" after entering INSERT, a held `s` would
        // toggle speak-under-pointer repeatedly, a held `u` would launch
        // multiple updates, and a held Escape/`r` would restart or stop reads.
        if isAutorepeat, Self.oneShotNormalKeys.contains(keycode) {
            return nil
        }

        switch keycode {
        case 34: // i — enter INSERT mode
            mode = .insert
            suppressInsertEntryRepeat = true
            fputs("[keyboard] → INSERT\n", stderr)
            // Same falling sweep as the typing rescue — INSERT entry always
            // sounds the same, however you got there.
            DispatchQueue.main.async { Earcon.fallToInsert() }
            return nil

        case 32: // u — check for updates + speak what's new. uu (burst) or a
                 // second u while the check is armed actually installs — the
                 // daemon owns that decision.
            DispatchQueue.main.async { [self] in
                fputs("[keyboard] u → update check\n", stderr)
                onUpdateCheck?()
            }
            return nil

        case 9: // v — visual mode; V (shift) — visual line mode
            pendingCount = 0
            let lineMode = flags.contains(.maskShift)
            mode = lineMode ? .visualLine : .visual
            visualDidExtendSelection = lineMode // line mode selects on entry
            // AX state creation is synchronous IPC — keep it off the tap callback
            DispatchQueue.main.async { [self] in
                visualAXState = Self.tryCreateVisualAXState()
                let axTag = visualAXState != nil ? " (AX)" : ""
                if lineMode {
                    if visualAXState != nil {
                        axSelectCurrentLine()
                    } else {
                        postKey(keycode: 123, command: true)
                        postKey(keycode: 125, shift: true)
                    }
                    fputs("[keyboard] → VISUAL LINE\(axTag)\n", stderr)
                    onAnnounce?("visual line")
                } else {
                    fputs("[keyboard] → VISUAL\(axTag)\n", stderr)
                    onAnnounce?("visual")
                }
            }
            return nil

        case 15 where flags.contains(.maskShift): // R — read document from caret
            readDocumentFromCaret()
            return nil

        case 15: // r — read line (triple-click + speak)
            readAtPointer()
            return nil

        case 17: // t — speak time. tt (time + date) resolves in the burst
                 // layer, whose decision window replaces the old double-tap
                 // timer: a lone t reaches here on burst-timer expiry.
                 // (With typingRescue disabled there is no tt — each t
                 // speaks the time immediately.)
            DispatchQueue.main.async { [self] in
                onAnnounce?(Self.currentTime())
            }
            return nil

        case 1: // s — toggle Marduk's own pointer hover speech (HoverSpeech:
                // the reading voice, rate, and pitch — the macOS hover
                // feature and its shortcut setup are no longer involved)
            DispatchQueue.main.async { [self] in onHoverToggle?() }
            return nil

        case 45 where isFirefoxFrontmost: // n — Firefox Reader narration handoff
            // Marduk steps aside for Firefox's own Narrate: stop our
            // speech, pause media and HOLD it paused, then hand the n to
            // Firefox (Narrate treats n as play/pause). Second n (or
            // Escape) pauses narration and releases the media. Outside
            // Firefox, n stays a plain letter (falls to the default beep,
            // and typing rescue still treats words like "sun" as typing).
            DispatchQueue.main.async { [self] in
                if narrationActive {
                    // Always allowed to end the handoff, wherever focus is
                    narrationActive = false
                    fputs("[keyboard] narration off — releasing media\n", stderr)
                    postKey(keycode: 45)
                    onNarrate?(false)
                } else {
                    // Only start when focus is inside a Reader document —
                    // on a normal page n would pause media for nothing
                    guard Self.narrationContext() else {
                        Earcon.error()
                        return
                    }
                    startNarrationHandoff()
                }
            }
            return nil

        case 28 where isFirefoxFrontmost: // 8 — Reader mode + narration, one key
            // Post Firefox's reader toggle (Cmd+Option+R), wait for the
            // Reader document to exist, then run the narration handoff.
            // Already narrating: full round trip — stop, release media,
            // close Reader. Digits normally pass through in NORMAL; this
            // is the one exception, Firefox-frontmost only.
            if flags.contains(.maskShift) || hasOption { return pass }
            if isAutorepeat { return nil }
            DispatchQueue.main.async { [self] in
                if narrationActive {
                    narrationActive = false
                    fputs("[keyboard] 8 — narration off, closing reader\n", stderr)
                    onNarrate?(false)
                    postKey(keycode: 15, command: true, option: true)
                } else if Self.narrationContext() {
                    // Reader already open — just start narrating
                    startNarrationHandoff()
                } else {
                    fputs("[keyboard] 8 — opening reader mode\n", stderr)
                    postKey(keycode: 15, command: true, option: true)
                    pollForReader(attempt: 0)
                }
            }
            return nil

        case 53: // Escape — stop speech if speaking; end a narration handoff
            DispatchQueue.main.async { [self] in
                if narrationActive {
                    narrationActive = false
                    fputs("[keyboard] narration off (Escape) — releasing media\n", stderr)
                    postKey(keycode: 45)
                    onNarrate?(false)
                }
                if isSpeaking() { onStop?() }
            }
            return nil

        case 41 where flags.contains(.maskShift): // ":" — enter COMMAND mode
            if isAutorepeat { return nil }
            mode = .command
            commandBuffer = ""
            commandAbsorbTail = []
            scheduleCommandIdle()
            fputs("[keyboard] → COMMAND\n", stderr)
            DispatchQueue.main.async { [self] in
                if commandEchoEnabled { onAnnounce?("command") }
                onCommandChange?("", false)
            }
            return nil

        default:
            // Suppress only letter keys to prevent typing. Pass through space,
            // numbers, function keys, arrows, mouse button keycodes (Naga), and
            // everything else. Space (49) and k (40) intentionally bleed through
            // so they take their normal effect (e.g. page scroll).
            if Self.alphaKeyCodes.contains(keycode) {
                // Non-command letter key in NORMAL mode: it does nothing (and is
                // suppressed so it isn't typed). Beep so the user notices they're
                // in NORMAL mode and may want INSERT. First buzz of the session
                // also points at :help — new users hit this constantly without
                // knowing what the buzzer means.
                let firstBuzz = !didSpeakColonHint
                didSpeakColonHint = true
                DispatchQueue.main.async { [self] in
                    Earcon.error()
                    if firstBuzz {
                        // Fixed-length earcon (~0.11s), not speech — the
                        // stagger just keeps the buzz audible before speech.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
                            onAnnounce?("Press colon, shift semicolon, to open "
                                + "the command panel and see every option.")
                        }
                    }
                }
                return nil
            }
            return pass
        }
    }

    /// Read started/ended (the engine's readActive didSet, via the daemon).
    /// Main-thread only, synchronous with speak()/the delegate callbacks, so
    /// the tap can never see an active read without its capture. Entry only
    /// when read motions are on and the keyboard is ours; COMMAND keeps its
    /// line editor (confirmation reads right after a : command must not
    /// steal the palette's keys). Natural end just drops the capture — the
    /// underlying mode was never changed, so the user lands back exactly
    /// where they were (INSERT stays INSERT).
    func readStateChanged(_ active: Bool) {
        if active {
            guard readMotionsEnabled, isEnabled, mode != .command,
                  !readingCapture else { return }
            readingCapture = true
            fputs("[keyboard] → READING\n", stderr)
        } else if readingCapture {
            readingCapture = false
            resetReadMotionState()
            // A withheld Escape must not fire its hold on a dead read; its
            // trailing keyUp passes as an orphan, which apps ignore
            pendingReadingEscape?.cancel()
            pendingReadingEscape = nil
            // Hundreds of AXUIElement refs into a browser process must die
            // with the read, not linger until the next one
            clearWebReadAnchors()
            fputs("[keyboard] read ended → \(mode)\n", stderr)
        } else {
            clearWebReadAnchors()  // reads without capture (motions off) too
        }
    }

    /// Replaces the COMMAND-mode buffer (Tab autocomplete). Main-thread only,
    /// same as every other piece of tap state; re-fires onCommandChange so
    /// the palette re-renders.
    func replaceCommandBuffer(_ text: String, absorbing: String = "") {
        guard mode == .command else { return }
        commandBuffer = text
        commandAbsorbTail = Array(absorbing)
        scheduleCommandIdle()
        onCommandChange?(text, true)
    }

    /// Ends COMMAND mode from the daemon side — the auto-accept path, where
    /// an unambiguous buffer executes without Enter. Main-thread only; the
    /// mode didSet notifies the palette via onModeChange.
    func endCommandMode() {
        guard mode == .command else { return }
        commandBuffer = ""
        commandIdleTimer?.cancel()
        mode = .normal
    }

    /// Speak-the-options-on-pause: fires once, ~1.5s after the last
    /// COMMAND-mode keystroke. Every keystroke restarts it, so it only
    /// triggers when the user genuinely stops to think.
    private func scheduleCommandIdle() {
        commandIdleTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mode == .command else { return }
            self.onCommandIdle?()
        }
        commandIdleTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: - Escape Tap/Hold (INSERT mode)

    /// Escape keyUp: resolves a withheld press as a tap, or absorbs the
    /// trailing keyUp of a hold that already fired. Any other Escape keyUp
    /// passes through (apps ignore orphan keyUps anyway).
    private func handleEscapeKeyUp(pass: Unmanaged<CGEvent>) -> Unmanaged<CGEvent>? {
        if pendingReadingEscape != nil {
            // READING: released before the hold threshold — a tap = pause
            // (or resume a paused read), exactly like Space
            pendingReadingEscape?.cancel()
            pendingReadingEscape = nil
            DispatchQueue.main.async { [self] in onPauseToggle?() }
            return nil
        }
        if pendingEscapeHold != nil {
            flushPendingEscapeAsTap()
            return nil // the synthetic down+up replaces the real events
        }
        if escapeHoldFired {
            escapeHoldFired = false
            return nil
        }
        return pass
    }

    /// Deliver the withheld Escape press to the app as a synthetic tap.
    private func flushPendingEscapeAsTap() {
        pendingEscapeHold?.cancel()
        pendingEscapeHold = nil
        // postKey does CGEvent work — keep it off the tap callback
        DispatchQueue.main.async { [self] in postKey(keycode: 53) }
    }

    // MARK: - Typing-Burst Rescue (NORMAL mode)

    private enum BurstVerdict {
        case swallow                    // withheld/handled by the burst layer
        case pass(Unmanaged<CGEvent>?)  // verdict of a flush redispatch
    }

    // NORMAL-mode letters that are commands: s v r t u i. `i` counts —
    // mid-buffer it is a plausible deliberate command, and any following
    // non-command letter still flips the decision to typing.
    private static let commandLetterKeys: Set<Int64> = [1, 9, 15, 17, 32, 34]

    /// n (45) is a command ONLY while Firefox is frontmost (Reader
    /// narration handoff) — everywhere else it stays a plain letter, so
    /// typing rescue keeps treating all-command-plus-n words ("sun",
    /// "runs") as typing.
    private func isCommandLetter(_ keycode: Int64) -> Bool {
        Self.commandLetterKeys.contains(keycode) || (keycode == 45 && isFirefoxFrontmost)
    }

    // MARK: - Firefox Reader narration handoff

    /// Duck + hold media, silence Marduk (via onNarrate), then hand `n` to
    /// Firefox — Narrate treats it as play/pause. Main thread only.
    private func startNarrationHandoff() {
        narrationActive = true
        fputs("[keyboard] narration handoff to Firefox\n", stderr)
        onNarrate?(true)
        // Give the media pause a beat so narration and music don't talk
        // over each other at the start
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in
            guard narrationActive else { return }
            postKey(keycode: 45)
        }
    }

    /// After `8` posts Cmd+Option+R: the Reader document takes a beat to
    /// render and receive focus. Poll until narrationContext() flips, then
    /// start narrating; give up quietly-but-audibly after ~2.5s (page has
    /// no reader view, or focus never entered the document).
    private func pollForReader(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
            guard !narrationActive else { return }
            if Self.narrationContext() {
                startNarrationHandoff()
            } else if attempt < 10 {
                pollForReader(attempt: attempt + 1)
            } else {
                fputs("[keyboard] 8 — reader document never appeared\n", stderr)
                Earcon.error()
            }
        }
    }

    /// True when keyboard focus sits inside a Firefox Reader document — the
    /// context where `n` drives Narrate. Ascends from the focused element
    /// (self included) to the nearest AXWebArea and checks for an
    /// about:reader URL. Chrome text fields (URL bar, find bar) never reach
    /// a web area, and normal pages have normal URLs, so every typing
    /// context returns false. Main queue only — AX is synchronous IPC.
    static func narrationContext() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "org.mozilla.firefox" else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.5)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success,
              let raw = focusedRef,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        var element = raw as! AXUIElement

        for _ in 0..<15 {
            AXUIElementSetMessagingTimeout(element, 0.5)
            var roleRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            if roleRef as? String == "AXWebArea" {
                var urlRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    element, kAXURLAttribute as CFString, &urlRef
                ) == .success else { return false }
                let url = (urlRef as? URL)?.absoluteString ?? (urlRef as? String) ?? ""
                return url.hasPrefix("about:reader")
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element, kAXParentAttribute as CFString, &parentRef
            ) == .success,
                  let parent = parentRef,
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            element = parent as! AXUIElement
        }
        return false
    }

    // Visual motions that may legitimately follow a withheld `v`/`V`:
    // h j k l and g/G (no English word starts with those pairs, so fast
    // vj/Vj/vG power-use keeps working with zero added latency).
    private static let visualMotionKeys: Set<Int64> = [4, 38, 40, 37, 5]

    /// Decide what a NORMAL-mode keypress means while typing rescue is on.
    /// Returns nil when the burst layer has no opinion (fall through to the
    /// regular command dispatch).
    private func burstIntercept(
        event: CGEvent, keycode: Int64, isAutorepeat: Bool
    ) -> BurstVerdict? {
        let isLetter = Self.alphaKeyCodes.contains(keycode) || keycode == 40

        if isLetter {
            if isAutorepeat {
                // A held key's repeats never join the buffer and never beep
                // (single beep/command on expiry instead of a machine-gun).
                // Held k keeps repeating into the app even while a burst is
                // pending — its repeats are app-bound input (scroll), not
                // no-ops, and must not stall for the decision window.
                if keycode == 40 { return nil }
                return .swallow
            }

            if burstBuffer.isEmpty {
                // i → instant INSERT (the i-then-type flow must have zero
                // latency); k keeps its pass-through. Neither starts a buffer.
                if keycode == 34 || keycode == 40 { return nil }
                // If the copy fails we can't withhold — behave as today
                guard let copy = event.copy() else { return nil }
                burstBuffer = [copy]
                armBurstTimer()
                return .swallow
            }

            // tt: a t landing on a buffered t resolves immediately as
            // time + date (subsumes the old double-tap timer, and is
            // strictly faster). Any earlier buffered commands (s in s-t-t)
            // flush first so they aren't lost.
            if keycode == 17,
               burstBuffer.last?.getIntegerValueField(.keyboardEventKeycode) == 17 {
                var events = takeBurst()
                events.removeLast() // the first t of the pair — consumed by tt
                for ev in events {
                    if redispatch(ev) != nil { enqueueReplay(ev) }
                }
                DispatchQueue.main.async { [self] in
                    onAnnounce?(Self.currentTimeAndDate())
                }
                return .swallow
            }

            // uu: same double-tap resolution as tt — one u asks (speaks the
            // release notes), two installs.
            if keycode == 32,
               burstBuffer.last?.getIntegerValueField(.keyboardEventKeycode) == 32 {
                var events = takeBurst()
                events.removeLast() // the first u of the pair — consumed by uu
                for ev in events {
                    if redispatch(ev) != nil { enqueueReplay(ev) }
                }
                DispatchQueue.main.async { [self] in
                    // EXPRESS lane: the daemon installs immediately when any
                    // prior check knows updates exist, and degrades to a
                    // harmless check otherwise — so deliberate uu skips the
                    // notes, while a stray double-u on an up-to-date system
                    // (the field incident) can never install anything.
                    fputs("[keyboard] uu → express update\n", stderr)
                    onUpdate?()
                }
                return .swallow
            }

            // v + motion: deliberate fast visual-mode use. Flush the v
            // (enters visual synchronously), then redispatch the motion —
            // it lands in the visual block because mode already changed.
            if Self.visualMotionKeys.contains(keycode),
               burstBuffer[0].getIntegerValueField(.keyboardEventKeycode) == 9 {
                flushBurstAsCommands()
                return .pass(redispatch(event))
            }

            // A burst containing any non-command letter means typing. A
            // non-command letter can only ever sit at buffer position 0 (a
            // later one resolves the burst right here), so checking the head
            // plus the incoming key covers the whole buffer — this is what
            // rescues "hi"/"he"/"at", where the command letter comes second.
            let headIsCommand = isCommandLetter(
                burstBuffer[0].getIntegerValueField(.keyboardEventKeycode)
            )
            if headIsCommand, isCommandLetter(keycode) {
                // Still ambiguous (all commands so far) — keep collecting.
                // On expiry the whole buffer executes as commands, so
                // deliberate rapid command pairs (s then r) stay commands.
                if let copy = event.copy() { burstBuffer.append(copy) }
                armBurstTimer()
                return .swallow
            }

            declareTyping(currentEvent: event)
            return .swallow
        }

        // Non-letter key (space, digit, arrow, Escape…): resolve any pending
        // burst as commands first, then let this key take its normal —
        // possibly mode-changed — route (a digit after `v` lands in the
        // visual count-prefix; a space after `s i` passes into INSERT).
        if !burstBuffer.isEmpty {
            flushBurstAsCommands()
            let verdict = redispatch(event)
            if verdict != nil, let copy = event.copy() {
                // App-bound: queue behind any keys the flush itself queued
                // (e.g. "sir" + space — the r is still waiting to be posted)
                // so nothing races ahead of the ordered replay.
                enqueueReplay(copy)
                return .swallow
            }
            return .pass(verdict)
        }
        return nil
    }

    /// Arm (or push back) the burst decision timer.
    private func armBurstTimer() {
        burstTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.burstTimer = nil
            self.flushBurstAsCommands()
        }
        burstTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + typingBurstThreshold, execute: work)
    }

    /// Cancel the decision timer and take ownership of the withheld events.
    private func takeBurst() -> [CGEvent] {
        burstTimer?.cancel()
        burstTimer = nil
        let events = burstBuffer
        burstBuffer = []
        return events
    }

    /// Drop all withheld and queued state without executing or replaying it
    /// (mode toggle / teardown — a half-decided burst must not fire later).
    private func discardBurstAndReplay() {
        _ = takeBurst()
        replayQueue = []
    }

    /// Resolve the withheld burst as deliberate commands: redispatch each
    /// buffered event through the real, mode-aware handler. A buffered
    /// command can change mode mid-flush (after a buffered `i` flips to
    /// INSERT, later keys must be typed, not run as commands), so this must
    /// not short-circuit into a NORMAL-only dispatch. A pass verdict means
    /// the event turned out to be app-bound and was never really delivered —
    /// queue it for ordered posting.
    private func flushBurstAsCommands() {
        for ev in takeBurst() {
            if redispatch(ev) != nil { enqueueReplay(ev) }
        }
    }

    /// Re-enter handleEvent with the burst hook bypassed, so the event
    /// reaches the regular dispatch for whatever mode the flush is in. The
    /// only place that touches isFlushingBurst.
    private func redispatch(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        isFlushingBurst = true
        defer { isFlushingBurst = false }
        return handleEvent(type: .keyDown, event: event)
    }

    /// The burst looks like typing: drop into INSERT and replay the
    /// withheld keys into the app so nothing is lost.
    private func declareTyping(currentEvent: CGEvent) {
        var events = takeBurst()
        if let copy = currentEvent.copy() { events.append(copy) }
        // A burst that resolves as typing predates any read that started
        // mid-burst — the user's typing intent wins over the capture
        readingCapture = false
        mode = .insert
        fputs("[keyboard] typing burst (\(events.count) keys) → INSERT\n", stderr)
        DispatchQueue.main.async { Earcon.fallToInsert() }
        for ev in events { enqueueReplay(ev) }
    }

    /// Tag an app-bound event with the synthetic marker and queue it; a
    /// single main-queue drain posts the queue in order, as down+up PAIRS.
    /// The pair matters: the key's real keyUp was never intercepted and
    /// usually reached the app BEFORE this down gets posted, so it cannot
    /// complete the pair — without a synthetic up, apps that track key-held
    /// state (games, hold-to-preview UIs) see the key stuck down forever.
    private func enqueueReplay(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        replayQueue.append(event)
        if replayQueue.count > 1 { return } // a drain is already scheduled
        DispatchQueue.main.async { [self] in
            for down in replayQueue {
                down.post(tap: .cghidEventTap)
                let keycode = CGKeyCode(down.getIntegerValueField(.keyboardEventKeycode))
                if let source = CGEventSource(stateID: .hidSystemState),
                   let up = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: false) {
                    up.flags = down.flags
                    up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
                    up.post(tap: .cghidEventTap)
                }
            }
            replayQueue = []
        }
    }

    // NORMAL-mode command keys that must fire once per physical press —
    // derived from commandLetterKeys so a future command letter can't be
    // added to one set but not the other, plus Escape (53).
    // 45 = n: one-shot even though it's only a command in Firefox —
    // suppressing a held n's autorepeat everywhere is harmless (NORMAL
    // mode letters don't type anyway)
    private static let oneShotNormalKeys: Set<Int64> = commandLetterKeys.union([53, 45])

    // macOS key codes for a-z suppressed in Normal mode to prevent typing.
    // Note: k (40) is deliberately omitted so it passes through to the app.
    /// Keycode → typed character for COMMAND-mode input and typing echo
    /// (US ANSI; shift ignored — the parser is case-insensitive anyway).
    private static let commandKeyChars: [Int64: Character] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
        8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y",
        17: "t", 31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k",
        45: "n", 46: "m",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4",
        23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        49: " ",
    ]

    /// Unmapped keys that are still "typing" (punctuation row) — in COMMAND
    /// mode these buzz instead of leaking into the app. Everything else
    /// unmapped passes through (F-keys, keypad, custom shortcut codes).
    private static let typingPunctuationKeys: Set<Int64> = [
        24, 27, 30, 33, 39, 41, 42, 43, 44, 47, 50,  // = - ] [ ' ; \ , / . `
    ]

    private static let alphaKeyCodes: Set<Int64> = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, // a-r, roughly
        31, 32, 34, 35, 37, 38, 45, 46                              // o-z, roughly (minus k=40)
    ]

    /// R — continuous reading: the focused element's FULL text from the
    /// caret (or selection start) to the end, through the normal read
    /// pipeline, so every reading-mode feature (motions, search, spell,
    /// purple border) applies for free. Mirrors tryCreateVisualAXState's
    /// extraction minus the settable-selection gate — reading needs no
    /// writable selection. Apps without an AX text value (web areas,
    /// canvas UIs) buzz and say so. Main-queue AX, 0.5s timeouts.
    private func readDocumentFromCaret() {
        DispatchQueue.main.async { [self] in
            func noDocument(_ why: String) {
                fputs("[keyboard] R: \(why)\n", stderr)
                Earcon.error()
                onAnnounce?("No readable document here.")
            }
            guard let app = NSWorkspace.shared.frontmostApplication else { return }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.5)

            var focusedRef: CFTypeRef?
            let focusErr = AXUIElementCopyAttributeValue(
                axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef)
            guard focusErr == .success,
                  let raw = focusedRef,
                  CFGetTypeID(raw) == AXUIElementGetTypeID() else {
                // Tell the TRUTH about a broken permission — "no readable
                // document" sent the user hunting the wrong problem while
                // the real one was a revoked Accessibility grant
                if focusErr.rawValue == -25211 {
                    Self.noteAXError(focusErr.rawValue)
                    fputs("[keyboard] R: AX API disabled (-25211)\n", stderr)
                    Earcon.error()
                    return
                }
                return noDocument("no focused element (\(focusErr.rawValue))")
            }
            var element = raw as! AXUIElement
            AXUIElementSetMessagingTimeout(element, 0.5)

            var valueRef: CFTypeRef?
            var valueErr = AXUIElementCopyAttributeValue(
                element, kAXValueAttribute as CFString, &valueRef)
            if valueErr != .success || (valueRef as? String)?.isEmpty != false {
                // The focused element may be a CONTAINER (Notes focuses a
                // wrapper view) — descend to the first real text area
                // before giving up on the app entirely
                if let textArea = Self.findDescendant(of: element,
                                                      role: "AXTextArea",
                                                      depthBudget: 8) {
                    element = textArea
                    AXUIElementSetMessagingTimeout(element, 0.5)
                    valueRef = nil
                    valueErr = AXUIElementCopyAttributeValue(
                        element, kAXValueAttribute as CFString, &valueRef)
                    if valueErr == .success {
                        fputs("[keyboard] R: descended to text area\n", stderr)
                    }
                }
            }
            guard valueErr == .success,
                  let text = valueRef as? String, !text.isEmpty else {
                // No AX text — PDF viewers (Preview) expose almost none.
                // Fall back to reading the FILE: the window's document
                // path + PDFKit gives per-page text, and pages become
                // first-class reading targets. Browsers expose no AX text
                // VALUE either, but their web-area trees hold the visible
                // text — the web-page path walks it (Reader views become
                // clean article reads).
                if !readPDFDocument(app: app) {
                    readWebPage(app: app)
                }
                return
            }

            // Start position: the character under the mouse POINTER wins
            // when it's over this element's text — in Terminal the shell
            // caret is pinned to the prompt, so pointing is the only way
            // to say "start here"; in editable apps clicking moves the
            // caret to the pointer anyway, so the two rarely disagree.
            // Falls back to the caret / selection start, then the top.
            // Snapped to the word start, same landing rule as char-find.
            var start = 0
            // Start priority: an EXPLICIT selection outranks everything —
            // Cmd+A then R means "read it all from the top", a selected
            // word means "start here"; the user just said what they want
            // (user-requested). A collapsed cursor (length 0) claims
            // nothing and falls through to the pointer chain. The pointer
            // is by definition ON SCREEN — an offset outside the visible
            // character range is provably garbage (field: Terminal with a
            // 9M-char scrollback answered RangeForPosition with ~2k, the
            // top of the buffer, while the user pointed at the visible
            // bottom). Reject it and let the row estimate — built FROM the
            // visible range — take over. Then the caret, then the top.
            var selection = CFRange(location: 0, length: 0)
            var rangeRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                   element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
               ) == .success,
               let rr = rangeRef, CFGetTypeID(rr) == AXValueGetTypeID() {
                _ = AXValueGetValue(rr as! AXValue, .cfRange, &selection)
            }
            let visibleRange = Self.visibleCharacterRange(of: element)
            if selection.length > 0 {
                start = max(0, selection.location)
                fputs("[keyboard] R: starting at selection\n", stderr)
            } else if let pointerOffset = Self.textOffsetAtPointer(in: element),
               Self.validatedPointerOffset(pointerOffset,
                                           visible: visibleRange) != nil {
                start = pointerOffset
                fputs("[keyboard] R: starting at pointer\n", stderr)
            } else if let estimate = Self.pointerRowEstimate(in: element,
                                                            text: text as NSString) {
                start = estimate
                fputs("[keyboard] R: starting at pointer (row estimate)\n", stderr)
            } else {
                start = max(0, selection.location)  // caret position
            }
            start = ReadNavigator.wordStart(in: text, at: start)

            let ns = text as NSString
            let remainder = ns.substring(from: min(start, ns.length))
            guard !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                fputs("[keyboard] R: nothing after the caret\n", stderr)
                Earcon.error()
                onAnnounce?("Nothing after the cursor to read.")
                return
            }
            fputs("[keyboard] R: document read (\(remainder.count) of \(ns.length) chars)\n", stderr)
            // Full text + start, not the sliced remainder: a huge document
            // gets chunked into pages around the exact start offset, so
            // pre-caret text stays reachable (gg = the true top).
            onSpeakDocument?(text, start)
        }
    }

    /// Row-estimate fallback for pointer starts when the app doesn't
    /// answer range-for-position (Terminal, empirically): the pointer's
    /// vertical fraction of the element's frame picks a line inside the
    /// VISIBLE character range. Terminal rows are uniform height, so this
    /// is line-accurate — all a "start here" gesture needs (the wordStart
    /// snap afterwards lands cleanly).
    /// Pure sanity check, unit-tested: a pointer-derived text offset must
    /// lie within the element's visible character range (nil range = no
    /// information, trust the offset). Returns nil for garbage.
    static func validatedPointerOffset(_ offset: Int, visible: NSRange?) -> Int? {
        guard let visible, visible.length > 0 else { return offset }
        let inRange = offset >= visible.location
            && offset <= visible.location + visible.length
        if !inRange {
            fputs("[keyboard] R: pointer offset \(offset) outside visible "
                + "range \(visible.location)..\(visible.location + visible.length) "
                + "— using row estimate\n", stderr)
        }
        return inRange ? offset : nil
    }

    private static func visibleCharacterRange(of element: AXUIElement) -> NSRange? {
        var visRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, kAXVisibleCharacterRangeAttribute as CFString,
                  &visRef) == .success,
              let vr = visRef, CFGetTypeID(vr) == AXValueGetTypeID() else { return nil }
        var visible = CFRange(location: 0, length: 0)
        guard AXValueGetValue(vr as! AXValue, .cfRange, &visible) else { return nil }
        return NSRange(location: visible.location, length: visible.length)
    }

    private static func pointerRowEstimate(in element: AXUIElement,
                                           text: NSString) -> Int? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        var visRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(
                  element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              AXUIElementCopyAttributeValue(
                  element, kAXVisibleCharacterRangeAttribute as CFString, &visRef) == .success,
              let pr = posRef, CFGetTypeID(pr) == AXValueGetTypeID(),
              let sr = sizeRef, CFGetTypeID(sr) == AXValueGetTypeID(),
              let vr = visRef, CFGetTypeID(vr) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        var visible = CFRange(location: 0, length: 0)
        guard AXValueGetValue(pr as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sr as! AXValue, .cgSize, &size), size.height > 0,
              AXValueGetValue(vr as! AXValue, .cfRange, &visible),
              visible.length > 0 else { return nil }

        // AX frames are top-left origin, same conversion as textOffsetAtPointer
        let mouse = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let axY = primaryHeight - mouse.y
        let fraction = max(0.0, min(1.0, (axY - origin.y) / size.height))

        let visStart = max(0, min(visible.location, text.length))
        let visEnd = max(visStart, min(visible.location + visible.length, text.length))
        let visibleText = text.substring(
            with: NSRange(location: visStart, length: visEnd - visStart))
        let lines = visibleText.components(separatedBy: "\n")
        guard !lines.isEmpty else { return nil }
        let targetLine = min(lines.count - 1, Int(fraction * CGFloat(lines.count)))
        var offset = visStart
        for index in 0..<targetLine {
            offset += (lines[index] as NSString).length + 1
        }
        return min(offset, text.length)
    }

    /// The text offset under the mouse pointer, via the parameterized
    /// AXRangeForPosition attribute (how hover speech maps pointer→text).
    /// Nil when the element doesn't support it or the pointer isn't over
    /// its text. AX coordinates are top-left origin; NSEvent's are
    /// bottom-left — flip against the primary screen's height.
    private static func textOffsetAtPointer(in element: AXUIElement) -> Int? {
        let mouse = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        var point = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
        guard let pointValue = AXValueCreate(.cgPoint, &point) else { return nil }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                  element,
                  kAXRangeForPositionParameterizedAttribute as CFString,
                  pointValue, &rangeRef
              ) == .success,
              let rr = rangeRef, CFGetTypeID(rr) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rr as! AXValue, .cfRange, &range),
              range.location >= 0 else { return nil }
        return range.location
    }

    /// Web-page fallback for R — ANY browser (Safari, Firefox, and the
    /// Chromium family get the same treatment):
    ///
    /// 1. AX WALK of the VISIBLE web area. With a Reader view open
    ///    (Safari Reader via Shift+Cmd+R, Firefox about:reader) the
    ///    visible area IS the stripped article, so the walk reads exactly
    ///    what Reader shows: title and body, no site clutter. (Reader is
    ///    an overlay: Safari AppleScript's `document` stays the full
    ///    underlying page — first-user-verified.) Firefox's `n` handoff
    ///    to its own Narrate is untouched — R is the Marduk-native
    ///    alternative with all the reading motions.
    /// 2. Thin harvest: Safari alone has an AppleScript whole-page
    ///    fallback (`text of front document`, clutter included; first
    ///    use fires the one-time Safari Automation prompt). Everything
    ///    else lands on the standard "No readable document here."
    ///
    /// Off-main throughout.
    /// Scripted whole-page text fallbacks for THIN AX harvests, per
    /// bundle — a table so new rows are data, but honestly narrow: Safari
    /// is the only browser whose AppleScript exposes the page text.
    static let scriptedTextFallbacks: [String: String] = [
        "com.apple.Safari": "tell application \"Safari\" to get text of front document",
    ]

    private func readWebPage(app: NSRunningApplication) {
        let pid = app.processIdentifier
        let fallbackScript = app.bundleIdentifier
            .flatMap { Self.scriptedTextFallbacks[$0] }
        fputs("[keyboard] R: web-area extraction\n", stderr)
        DispatchQueue.global(qos: .utility).async { [self] in
            if let harvest = Self.webAreaVisibleText(pid: pid),
               harvest.text.count > 200 {
                fputs("[keyboard] R: web-area walk (\(harvest.text.count) chars, "
                    + "\(harvest.anchors.count) anchors)\n", stderr)
                DispatchQueue.main.async { [self] in
                    // onSpeak → speak() → onNewRead clears stale anchors,
                    // THEN this read's anchors arm the scroll-follow
                    onSpeak?(harvest.text)
                    setWebReadAnchors(harvest.anchors)
                }
                return
            }
            guard let script = fallbackScript else {
                fputs("[keyboard] R: web-area walk thin, no fallback for this app\n", stderr)
                DispatchQueue.main.async { [self] in
                    Earcon.error()
                    onAnnounce?("No readable document here.")
                }
                return
            }
            fputs("[keyboard] R: AX walk thin — scripted fallback\n", stderr)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            var text: String?
            do {
                try process.run()
                // Drain before waiting — the pipe-buffer deadlock guard
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let err = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    text = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    let msg = String(data: err, encoding: .utf8) ?? ""
                    fputs("[keyboard] scripted extraction failed (status "
                        + "\(process.terminationStatus)): "
                        + "\(msg.trimmingCharacters(in: .whitespacesAndNewlines))\n", stderr)
                }
            } catch {
                fputs("[keyboard] osascript launch failed: \(error.localizedDescription)\n", stderr)
            }
            DispatchQueue.main.async { [self] in
                guard let text, !text.isEmpty else {
                    Earcon.error()
                    onAnnounce?("No readable document here.")
                    return
                }
                fputs("[keyboard] R: Safari page (\(text.count) chars)\n", stderr)
                onSpeakDocument?(text, 0)  // unbounded harvest — may page
            }
        }
    }

    /// Harvest the text visible in the app's front web area by walking
    /// its AX tree (static text + headings, in document order). Returns
    /// nil on a sparse tree — browsers populate web AX lazily; the
    /// nudges below help but only real hardware proves each browser.
    /// Budgeted: 0.25s per-element timeouts, capped node count and depth,
    /// so a pathological page can't wedge the walk. Runs OFF the main
    /// thread by design (a long walk on main would stall tap dispatch).
    private static func webAreaVisibleText(pid: pid_t)
        -> (text: String, anchors: [AXUIElement])? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        // The screen-reader nudges: browsers keep web AX trees minimal
        // until an assistive client announces itself. EnhancedUserInterface
        // is the WebKit/Gecko signal; ManualAccessibility is the
        // Chromium/Electron one — setting both is harmless.
        AXUIElementSetAttributeValue(
            axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(
            axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.3) // let the tree populate

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  axApp, kAXFocusedWindowAttribute as CFString, &windowRef
              ) == .success,
              let rawWindow = windowRef,
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { return nil }

        // Find the web area, then collect text below it
        guard let webArea = findDescendant(
            of: rawWindow as! AXUIElement, role: "AXWebArea", depthBudget: 12
        ) else { return nil }

        var parts: [(text: String, element: AXUIElement)] = []
        var nodeBudget = 3000
        collectText(from: webArea, into: &parts, nodeBudget: &nodeBudget, depth: 40)
        let joined = parts.map(\.text).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return nil }
        // One anchor PER LINE of the joined text (a node's text can itself
        // contain newlines), so line index → contributing element is exact
        // before preprocessing and within a line or two after
        var anchors: [AXUIElement] = []
        for part in parts {
            let lines = part.text.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
            anchors.append(contentsOf: Array(repeating: part.element, count: lines))
        }
        return (joined, anchors)
    }

    private static func findDescendant(
        of element: AXUIElement, role: String, depthBudget: Int
    ) -> AXUIElement? {
        guard depthBudget > 0 else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)
        var roleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if roleRef as? String == role { return element }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, kAXChildrenAttribute as CFString, &childrenRef
              ) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let found = findDescendant(of: child, role: role,
                                          depthBudget: depthBudget - 1) {
                return found
            }
        }
        return nil
    }

    private static func collectText(
        from element: AXUIElement, into parts: inout [(text: String, element: AXUIElement)],
        nodeBudget: inout Int, depth: Int
    ) {
        guard depth > 0, nodeBudget > 0 else { return }
        nodeBudget -= 1
        AXUIElementSetMessagingTimeout(element, 0.25)
        var roleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if let role = roleRef as? String,
           role == "AXStaticText" || role == "AXHeading" {
            var valueRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                   element, kAXValueAttribute as CFString, &valueRef
               ) == .success,
               let text = valueRef as? String,
               !text.trimmingCharacters(in: .whitespaces).isEmpty {
                parts.append((text, element))
            }
            if role == "AXStaticText" { return } // leaves have no useful children
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, kAXChildrenAttribute as CFString, &childrenRef
              ) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            guard nodeBudget > 0 else { return }
            collectText(from: child, into: &parts, nodeBudget: &nodeBudget, depth: depth - 1)
        }
    }

    /// PDF fallback for R: the focused window's document path (standard
    /// NSDocument AX) → PDFKit per-page text → paged read. Start page
    /// comes from Preview's "Page 3 of 12" window title when parseable.
    /// AX stays on main; the PDFKit load (big files take a moment) hops
    /// to a utility queue and dispatches back. Returns false when there's
    /// no PDF to try (caller falls through to the normal buzz).
    /// Main-thread only.
    private func readPDFDocument(app: NSRunningApplication) -> Bool {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.5)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  axApp, kAXFocusedWindowAttribute as CFString, &windowRef
              ) == .success,
              let rawWindow = windowRef,
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { return false }
        let window = rawWindow as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.5)

        var documentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  window, kAXDocumentAttribute as CFString, &documentRef
              ) == .success else { return false }
        let documentPath = (documentRef as? String) ?? (documentRef as? URL)?.absoluteString ?? ""
        guard documentPath.lowercased().hasSuffix(".pdf"),
              let url = URL(string: documentPath).flatMap({ $0.isFileURL ? $0 : nil })
                  ?? (documentPath.hasPrefix("/") ? URL(fileURLWithPath: documentPath) : nil)
        else { return false }

        // Visible page from the window title, while we're on main with AX
        var titleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        let startPage = (titleRef as? String).flatMap(PagedText.previewPage(fromTitle:)) ?? 1

        fputs("[keyboard] R: PDF \(url.lastPathComponent), starting page \(startPage)\n", stderr)
        DispatchQueue.global(qos: .utility).async { [self] in
            let paged = PagedText.load(url: url)
            DispatchQueue.main.async { [self] in
                guard let paged else {
                    Earcon.error()
                    onAnnounce?("No readable document here.")
                    return
                }
                onSpeakPaged?(paged, startPage)
            }
        }
        return true
    }

    /// The `r` command: triple-click selects the paragraph under the
    /// pointer, then read the selection. Shared by the NORMAL dispatch and
    /// the READING capture — r mid-read is a clear "read that instead", and
    /// the new speak() replaces the current utterance seamlessly (stale
    /// didCancel: media stays ducked, capture stays engaged).
    private func readAtPointer() {
        DispatchQueue.main.async { [self] in
            tripleClickAtCursor()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
                Self.readSelection { [self] text in onSpeakDocument?(text, 0) }
            }
        }
    }

    // MARK: - Triple Click

    private func tripleClickAtCursor() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let pos = CGEvent(source: nil)?.location ?? .zero

        for clickCount: Int64 in 1...3 {
            guard let down = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: pos,
                mouseButton: .left
            ), let up = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: pos,
                mouseButton: .left
            ) else { return }

            down.setIntegerValueField(.mouseEventClickState, value: clickCount)
            down.post(tap: .cghidEventTap)

            up.setIntegerValueField(.mouseEventClickState, value: clickCount)
            up.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Visual follow (the view tracks the read)

    /// Master switch (`:config follow`, keyboard.follow). Gates both the
    /// Preview go-to-page gesture and web scroll-follow.
    var followEnabled = true

    /// Go-to-page keyboard gestures per PDF viewer. v1 ships Preview
    /// (Cmd+Option+G opens its Go to Page sheet); other viewers join once
    /// their chords — and AXDocument exposure — are verified on hardware.
    struct PageChord {
        let keycode: CGKeyCode
        let command: Bool
        let option: Bool
        let shift: Bool
    }
    static let pageChords: [String: PageChord] = [
        "com.apple.Preview": PageChord(keycode: 5, command: true, option: true,
                                       shift: false),  // Cmd+Option+G
    ]

    /// Fire the viewer's go-to-page gesture: chord, pause for the sheet,
    /// digits, Return. Marker-tagged synthetic events pass our own tap
    /// even during READING capture. Fire-and-forget — a missed gesture
    /// never disturbs the read.
    func postGoToPage(_ page: Int, chord: PageChord) {
        guard followEnabled else { return }
        postKey(keycode: chord.keycode, shift: chord.shift,
                command: chord.command, option: chord.option)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            for code in Self.digitKeycodes(page) { postKey(keycode: code) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                postKey(keycode: 36)  // Return
            }
        }
    }

    /// ANSI number-row keycodes for a page number's digits, typing order.
    static func digitKeycodes(_ n: Int) -> [CGKeyCode] {
        let keys: [Character: CGKeyCode] = ["0": 29, "1": 18, "2": 19, "3": 20,
                                            "4": 21, "5": 23, "6": 22, "7": 26,
                                            "8": 28, "9": 25]
        return String(max(0, n)).compactMap { keys[$0] }
    }

    // Web scroll-follow: anchors[i] = the AX element that contributed line
    // i of the harvested article. As the read position crosses lines, the
    // contributing element is asked to scroll itself visible — Reader
    // articles track the voice like Firefox's own Narrate. Preprocessing
    // can drop the odd line, so the index is clamped: ±1 paragraph drift
    // is invisible at scroll granularity.
    private var webReadAnchors: [AXUIElement] = []
    private var followAnchorIndex = -1
    private var followLastScroll = Date.distantPast
    private var followScrollBroken = false

    func setWebReadAnchors(_ anchors: [AXUIElement]) {
        webReadAnchors = anchors
        followAnchorIndex = -1
        followLastScroll = .distantPast
        followScrollBroken = false
    }

    func clearWebReadAnchors() {
        webReadAnchors = []
    }

    /// Read position moved (Daemon relays SpeechEngine.onPositionChange
    /// with the processed read text). Main queue, NEVER the tap callback —
    /// the scroll is a synchronous AX call.
    func followScroll(offset: Int, text: String) {
        guard followEnabled, !webReadAnchors.isEmpty, !followScrollBroken else { return }
        let line = Self.lineIndex(of: offset, in: text)
        let anchorIndex = max(0, min(line, webReadAnchors.count - 1))
        guard anchorIndex != followAnchorIndex,
              Date().timeIntervalSince(followLastScroll) >= 0.8 else { return }
        followAnchorIndex = anchorIndex
        followLastScroll = Date()
        let element = webReadAnchors[anchorIndex]
        AXUIElementSetMessagingTimeout(element, 0.25)
        let err = AXUIElementPerformAction(element, "AXScrollToVisible" as CFString)
        if err != .success {
            // One log line, then stop trying for this read — support for
            // the action is per-app and a dead one mustn't cost an AX
            // round-trip every paragraph
            followScrollBroken = true
            fputs("[keyboard] follow: scroll action unsupported (\(err.rawValue))\n", stderr)
        }
    }

    /// Newlines before `offset` — the line index the voice is on.
    static func lineIndex(of offset: Int, in text: String) -> Int {
        let ns = text as NSString
        let end = max(0, min(offset, ns.length))
        var count = 0
        var i = 0
        while i < end {
            if ns.character(at: i) == 0x0A { count += 1 }
            i += 1
        }
        return count
    }

    // MARK: - Synthetic Key Posting

    /// Post a synthetic key event (for visual mode selection).
    /// Tagged with syntheticMarker so our event tap passes them through.
    private func postKey(keycode: CGKeyCode, shift: Bool = false, command: Bool = false,
                         option: Bool = false, count: Int = 1) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        var flags: CGEventFlags = []
        if shift { flags.insert(.maskShift) }
        if command { flags.insert(.maskCommand) }
        if option { flags.insert(.maskAlternate) }

        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: false) else { continue }
            down.flags = flags
            down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            down.post(tap: .cghidEventTap)

            up.flags = flags
            up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            up.post(tap: .cghidEventTap)
        }
    }

    // MARK: - AX-Based Visual Selection

    private static func tryCreateVisualAXState() -> VisualAXState? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Don't let a hung app stall us for the 6-second default AX timeout
        AXUIElementSetMessagingTimeout(axApp, 0.5)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success,
              let focused = focusedRef,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.5)

        // Must support settable selection range
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            element, kAXSelectedTextRangeAttribute as CFString, &settable
        ) == .success, settable.boolValue else { return nil }

        // Get current insertion point
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success,
              let rangeVal = rangeRef,
              CFGetTypeID(rangeVal) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeVal as! AXValue, .cfRange, &range) else { return nil }

        // Get text content for line navigation
        var textRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &textRef
        ) == .success, let text = textRef as? String else { return nil }

        let position = range.location + range.length
        fputs("[keyboard] AX visual: position=\(position), textLength=\(text.count)\n", stderr)
        return VisualAXState(element: element, text: text as NSString, anchor: position, cursor: position)
    }

    private enum AXMotionDirection { case left, right, up, down, toEnd }

    private func axMotion(_ direction: AXMotionDirection, count: Int) {
        guard var state = visualAXState else { return }
        let length = state.text.length

        switch direction {
        case .left:
            state.cursor = max(0, state.cursor - count)
        case .right:
            state.cursor = min(length, state.cursor + count)
        case .down:
            var pos = state.cursor
            for _ in 0..<count {
                let remaining = NSRange(location: pos, length: length - pos)
                let nl = state.text.range(of: "\n", range: remaining)
                if nl.location != NSNotFound {
                    pos = nl.location + 1
                } else {
                    pos = length
                    break
                }
            }
            state.cursor = pos
        case .up:
            var pos = state.cursor
            for _ in 0..<count {
                if pos == 0 { break }
                let searchRange = NSRange(location: 0, length: max(0, pos - 1))
                let nl = state.text.range(of: "\n", options: .backwards, range: searchRange)
                if nl.location != NSNotFound {
                    pos = nl.location
                } else {
                    pos = 0
                    break
                }
            }
            state.cursor = pos
        case .toEnd:
            state.cursor = length
        }

        visualAXState = state
        applyAXSelection()
    }

    private func axSelectCurrentLine() {
        guard var state = visualAXState else { return }
        let length = state.text.length
        let pos = state.cursor

        // Find start of current line
        var lineStart = 0
        if pos > 0 {
            let before = NSRange(location: 0, length: pos)
            let nl = state.text.range(of: "\n", options: .backwards, range: before)
            lineStart = nl.location != NSNotFound ? nl.location + 1 : 0
        }

        // Find end of current line (include newline)
        let after = NSRange(location: pos, length: length - pos)
        let nl = state.text.range(of: "\n", range: after)
        let lineEnd = nl.location != NSNotFound ? nl.location + 1 : length

        state.anchor = lineStart
        state.cursor = lineEnd
        visualAXState = state
        applyAXSelection()
    }

    private func applyAXSelection() {
        guard let state = visualAXState else { return }
        var start = min(state.anchor, state.cursor)
        var end = max(state.anchor, state.cursor)

        // For visual line mode, expand to full lines
        if mode == .visualLine {
            let text = state.text
            let length = text.length

            if start > 0 {
                let before = NSRange(location: 0, length: start)
                let nl = text.range(of: "\n", options: .backwards, range: before)
                start = nl.location != NSNotFound ? nl.location + 1 : 0
            }
            if end < length {
                let after = NSRange(location: end, length: length - end)
                let nl = text.range(of: "\n", range: after)
                end = nl.location != NSNotFound ? nl.location + 1 : length
            }
        }

        var range = CFRange(location: start, length: end - start)
        guard let rangeVal = AXValueCreate(.cfRange, &range) else { return }
        AXUIElementSetAttributeValue(state.element, kAXSelectedTextRangeAttribute as CFString, rangeVal)
    }

    /// Queue a visual-mode hjkl motion. The AX-vs-synthetic-key decision is
    /// made inside the block so it sees the visualAXState created by the
    /// (also queued) mode-entry block, even if the keys arrived back-to-back.
    private func extendSelection(_ direction: AXMotionDirection, arrowKeycode: CGKeyCode) {
        let count = max(1, pendingCount)
        pendingCount = 0
        visualDidExtendSelection = true
        DispatchQueue.main.async { [self] in
            if visualAXState != nil {
                axMotion(direction, count: count)
            } else {
                postKey(keycode: arrowKeycode, shift: true, count: count)
            }
        }
    }

    /// Collapse the visual selection (mode/count are reset by the caller
    /// inside the tap callback; this part does the slow AX/CGEvent work).
    private func collapseVisualSelection() {
        if let state = visualAXState {
            // Collapse selection to cursor position via AX
            var range = CFRange(location: state.cursor, length: 0)
            if let rangeVal = AXValueCreate(.cfRange, &range) {
                AXUIElementSetAttributeValue(state.element, kAXSelectedTextRangeAttribute as CFString, rangeVal)
            }
            visualAXState = nil
        } else if visualDidExtendSelection {
            postKey(keycode: 124) // Right arrow collapses selection
        }
        visualDidExtendSelection = false
    }

    // MARK: - Time / Date

    private static func spokenTime() -> String {
        let cal = Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)

        let hourPart = hour < 10 ? "oh \(hour)" : "\(hour)"
        let minutePart: String
        if minute == 0 {
            minutePart = "hundred"
        } else if minute < 10 {
            minutePart = "oh \(minute)"
        } else {
            minutePart = "\(minute)"
        }
        return "\(hourPart) \(minutePart)"
    }

    private static func currentTime() -> String {
        spokenTime()
    }

    private static func currentTimeAndDate() -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM"
        return "\(spokenTime()), \(f.string(from: Date()))"
    }

    // MARK: - AX Selected Text

    /// Speak-the-selection with resilience: AX first, clipboard-copy
    /// fallback when AX fails or comes back empty. Huge selections (Cmd+A
    /// on a whole document) routinely exceed the 0.5s AX messaging timeout,
    /// and some apps never expose kAXSelectedTextAttribute at all — without
    /// the fallback those reads are silent no-ops. Shared by Option+Escape,
    /// normal-mode r (post triple-click), and visual r. Main queue only;
    /// `deliver` is called at most once, never with empty text.
    static func readSelection(_ deliver: @escaping (String) -> Void) {
        if let text = getSelectedText(), !text.isEmpty {
            fputs("[keyboard] speak selection (\(text.count) chars)\n", stderr)
            deliver(text)
            return
        }
        copySelectionAndRead { text in
            guard let text, !text.isEmpty else { return }
            fputs("[keyboard] speak selection via clipboard fallback (\(text.count) chars)\n", stderr)
            deliver(text)
        }
    }

    /// Fired once per session when AX calls start failing with
    /// kAXErrorAPIDisabled (-25211): the Accessibility grant broke (an
    /// update's re-sign is the usual culprit) while the already-created
    /// tap kept running — a uniquely confusing half-alive state.
    nonisolated(unsafe) static var onAXRevoked: (() -> Void)?
    private nonisolated(unsafe) static var axRevokedNoticed = false

    static func noteAXError(_ code: Int32) {
        guard code == -25211, !axRevokedNoticed else { return }
        axRevokedNoticed = true
        DispatchQueue.main.async { onAXRevoked?() }
    }

    static func getSelectedText() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Don't let a hung app stall us for the 6-second default AX timeout
        AXUIElementSetMessagingTimeout(axApp, 0.5)

        var focusedElement: CFTypeRef?
        let focusErr = AXUIElementCopyAttributeValue(
            axApp, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard focusErr == .success,
              let focused = focusedElement,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            if focusErr != .success {
                fputs("[keyboard] AX focused-element copy failed (\(focusErr.rawValue))\n", stderr)
                noteAXError(focusErr.rawValue)
            }
            return nil
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.5)

        var selectedText: CFTypeRef?
        let textErr = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &selectedText)
        guard textErr == .success else {
            // -1001 CannotComplete is the 0.5s timeout — typically a huge
            // Cmd+A selection; the clipboard fallback in readSelection
            // covers it
            fputs("[keyboard] AX selected-text copy failed (\(textErr.rawValue))\n", stderr)
            return nil
        }

        return selectedText as? String
    }

    // (The old macOS speak-under-pointer integration — the Ctrl+Option+
    // Cmd+P shortcut post, the media pause/resume dance, and the
    // isAudioOutputRunning device check — is gone: `s` now drives
    // Marduk's own HoverSpeech, which uses the reading voice and needs
    // neither Settings setup nor media pausing.)

    /// Fallback for apps where AX selected text isn't available (e.g. iMessage).
    /// Posts Cmd+C to copy selection, then reads from pasteboard.
    static func copySelectionAndRead(completion: @escaping (String?) -> Void) {
        let pb = NSPasteboard.general
        let oldCount = pb.changeCount

        // Post Cmd+C (keycode 8 = 'c')
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else {
            completion(nil)
            return
        }
        down.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        down.post(tap: .cghidEventTap)

        up.flags = .maskCommand
        up.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        up.post(tap: .cghidEventTap)

        // Wait for pasteboard to update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if pb.changeCount != oldCount, let text = pb.string(forType: .string) {
                fputs("[keyboard] clipboard fallback: got \(text.count) chars\n", stderr)
                completion(text)
            } else {
                completion(nil)
            }
        }
    }
}
