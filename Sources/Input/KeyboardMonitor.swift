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

    enum Mode { case normal, insert, visual, visualLine }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapWatchdog: DispatchSourceTimer?
    private var tapRetry: DispatchSourceTimer?
    private var onSpeak: SpeakHandler?
    private var onStop: StopHandler?
    private var onAnnounce: AnnounceHandler?
    private var onUpdate: UpdateHandler?
    private var isSpeaking: () -> Bool = { false }
    private var isReadActive: () -> Bool = { false }
    private var onPauseToggle: (() -> Void)?
    private var stopped = false

    private(set) var isEnabled = true
    private(set) var mode: Mode = .normal

    // Speak-under-pointer state. The pause/resume work runs on a SERIAL queue
    // so rapid toggles can't interleave (the global concurrent queue let two
    // toggles race on didPauseMediaForSpeakUnderCursor and double-send the
    // play/pause key, which is a toggle and would start playback).
    private var speakUnderCursorActive = false
    private var didPauseMediaForSpeakUnderCursor = false
    private let mediaQueue = DispatchQueue(label: "com.marduk.keyboard.media")

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
        onPauseToggle: (() -> Void)? = nil
    ) {
        self.onSpeak = onSpeak
        self.onStop = onStop
        self.onAnnounce = onAnnounce
        self.onUpdate = onUpdate
        self.isSpeaking = isSpeaking
        self.isReadActive = isReadActive
        self.onPauseToggle = onPauseToggle

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
            if !CGEvent.tapIsEnabled(tap: tap) {
                fputs("[keyboard] event tap was disabled — re-enabling\n", stderr)
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        watchdog.resume()
        tapWatchdog = watchdog
        return true
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
        tapWatchdog?.cancel()
        tapWatchdog = nil
        tapRetry?.cancel()
        tapRetry = nil
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

        // Option+Escape — speak selection / stop speech
        if keycode == 53, hasOption {
            if isAutorepeat { return nil }
            DispatchQueue.main.async { [self] in
                if isSpeaking() {
                    onStop?()
                } else if let text = Self.getSelectedText(), !text.isEmpty {
                    fputs("[keyboard] speak selection (\(text.count) chars)\n", stderr)
                    onSpeak?(text)
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
            escapeHoldFired = false
            // Same for a half-decided typing burst: discard, don't flush
            discardBurstAndReplay()
            let state = isEnabled ? "ON (NORMAL)" : "OFF"
            fputs("[keyboard] Marduk \(state)\n", stderr)
            let word = isEnabled ? "Systems engaged" : "Systems disengaged"
            DispatchQueue.main.async { [self] in
                onAnnounce?(word)
                // TODO: replace with earcon bloops once audio is tuned
                // if isEnabled { Earcon.bloopUp() } else { Earcon.bloopDown() }
            }
            return nil
        }

        // === Marduk disabled: pass everything through ===
        guard isEnabled else { return pass }

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

        // === Space: pause/resume an active read (NORMAL/VISUAL only) ===
        // Only while a content read is speaking or paused — announcements
        // never capture Space, and otherwise it types/passes as normal.
        // INSERT means typing: Space is always a real space there, even
        // mid-read. A typing-rescue burst in flight means the user is
        // typing, so Space stays typing there too. Escape (NORMAL) cancels
        // a paused read — a paused synthesizer still counts as speaking —
        // which frees Space back to normal. isReadActive is plain stored
        // state on the speech engine, safe to read in the tap callback.
        if keycode == 49, mode != .insert, !hasCommand, !hasControl, !hasOption,
           !flags.contains(.maskShift), burstBuffer.isEmpty, isReadActive() {
            if isAutorepeat { return nil }
            DispatchQueue.main.async { [self] in onPauseToggle?() }
            return nil
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
                DispatchQueue.main.async { [self] in collapseVisualSelection() }
                fputs("[keyboard] → NORMAL\n", stderr)
                return nil

            case 15: // r — read selection, exit to normal
                mode = .normal
                pendingCount = 0
                DispatchQueue.main.async { [self] in
                    visualAXState = nil
                    if let text = Self.getSelectedText(), !text.isEmpty {
                        fputs("[keyboard] visual r → read selection (\(text.count) chars)\n", stderr)
                        onSpeak?(text)
                    } else {
                        Self.copySelectionAndRead { [self] text in
                            if let text, !text.isEmpty {
                                onSpeak?(text)
                            }
                        }
                    }
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
            return nil

        case 32: // u — update (pull + build + restart)
            DispatchQueue.main.async { [self] in
                onAnnounce?("Update initiated")
                fputs("[keyboard] u → pull + build\n", stderr)
                onUpdate?()
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

        case 15: // r — read line (triple-click + speak)
            DispatchQueue.main.async { [self] in
                tripleClickAtCursor()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
                    if let text = Self.getSelectedText(), !text.isEmpty {
                        onSpeak?(text)
                    } else {
                        // Fallback for apps where AX selected text doesn't work (e.g. iMessage):
                        // copy selection to clipboard via Cmd+C, then read pasteboard
                        Self.copySelectionAndRead { [self] text in
                            if let text, !text.isEmpty {
                                onSpeak?(text)
                            }
                        }
                    }
                }
            }
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

        case 1: // s — toggle macOS "speak item under pointer" (Ctrl+Option+Cmd+P shortcut)
            speakUnderCursorActive.toggle()
            let active = speakUnderCursorActive
            fputs("[keyboard] s → speak under pointer \(active ? "on" : "off")\n", stderr)
            mediaQueue.async { [self] in
                if active {
                    // Pause media before enabling speak-under-pointer
                    if Self.isAudioOutputRunning() {
                        fputs("[keyboard] pausing media for speak under pointer\n", stderr)
                        Self.sendMediaPlayPause()
                        didPauseMediaForSpeakUnderCursor = true
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                    Self.postSpeakUnderPointerShortcut()
                } else {
                    // Disable speak-under-pointer, then resume media if we paused it
                    Self.postSpeakUnderPointerShortcut()
                    if didPauseMediaForSpeakUnderCursor {
                        fputs("[keyboard] resuming media after speak under pointer\n", stderr)
                        Thread.sleep(forTimeInterval: 0.3)
                        Self.sendMediaPlayPause()
                        didPauseMediaForSpeakUnderCursor = false
                    }
                }
            }
            return nil

        case 53: // Escape — stop speech if speaking
            DispatchQueue.main.async { [self] in
                if isSpeaking() { onStop?() }
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
                // in NORMAL mode and may want INSERT.
                DispatchQueue.main.async { Earcon.error() }
                return nil
            }
            return pass
        }
    }

    // MARK: - Escape Tap/Hold (INSERT mode)

    /// Escape keyUp: resolves a withheld press as a tap, or absorbs the
    /// trailing keyUp of a hold that already fired. Any other Escape keyUp
    /// passes through (apps ignore orphan keyUps anyway).
    private func handleEscapeKeyUp(pass: Unmanaged<CGEvent>) -> Unmanaged<CGEvent>? {
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
            let headIsCommand = Self.commandLetterKeys.contains(
                burstBuffer[0].getIntegerValueField(.keyboardEventKeycode)
            )
            if headIsCommand, Self.commandLetterKeys.contains(keycode) {
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
    private static let oneShotNormalKeys: Set<Int64> = commandLetterKeys.union([53])

    // macOS key codes for a-z suppressed in Normal mode to prevent typing.
    // Note: k (40) is deliberately omitted so it passes through to the app.
    private static let alphaKeyCodes: Set<Int64> = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, // a-r, roughly
        31, 32, 34, 35, 37, 38, 45, 46                              // o-z, roughly (minus k=40)
    ]

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

    // MARK: - Synthetic Key Posting

    /// Post a synthetic key event (for visual mode selection).
    /// Tagged with syntheticMarker so our event tap passes them through.
    private func postKey(keycode: CGKeyCode, shift: Bool = false, command: Bool = false, count: Int = 1) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        var flags: CGEventFlags = []
        if shift { flags.insert(.maskShift) }
        if command { flags.insert(.maskCommand) }

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

    static func getSelectedText() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Don't let a hung app stall us for the 6-second default AX timeout
        AXUIElementSetMessagingTimeout(axApp, 0.5)

        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axApp, kAXFocusedUIElementAttribute as CFString, &focusedElement
        ) == .success,
              let focused = focusedElement,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.5)

        var selectedText: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &selectedText
        ) == .success else {
            return nil
        }

        return selectedText as? String
    }

    // MARK: - Speak Items Under Pointer (macOS Accessibility)

    /// Post Ctrl+Option+Cmd+P to toggle "Speak items under the pointer".
    /// Requires one-time setup: System Settings > Keyboard > Keyboard Shortcuts >
    /// Accessibility > assign Ctrl+Option+Cmd+P to "Speak items under the pointer".
    private static func postSpeakUnderPointerShortcut() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        // keycode 35 = 'p'
        let flags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 35, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 35, keyDown: false) else { return }

        down.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        down.post(tap: .cghidEventTap)

        up.flags = flags
        up.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        up.post(tap: .cghidEventTap)
    }

    /// Check if the default audio output device has active streams (i.e. something is playing).
    private static func isAudioOutputRunning() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr else { return false }

        var isRunning: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning) == noErr else { return false }
        return isRunning != 0
    }

    /// Send a system-wide media play/pause key event.
    private static func sendMediaPlayPause() {
        let keyType = 16 // NX_KEYTYPE_PLAY

        let downEvent = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xa00),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: (keyType << 16) | (0x0a << 8),
            data2: -1
        )
        downEvent?.cgEvent?.post(tap: .cghidEventTap)

        let upEvent = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xb00),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: (keyType << 16) | (0x0b << 8),
            data2: -1
        )
        upEvent?.cgEvent?.post(tap: .cghidEventTap)
    }

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
