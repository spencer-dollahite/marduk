import Foundation
import AppKit
import ApplicationServices
import AVFoundation

// Crash-restore state for the Karabiner profile handoff, file-scope so the
// signal handler (a C function, no captures) can reach it. Prepared on
// profile activation (main thread); the handler only reads. See
// DaemonServer.armCrashRestore.
private nonisolated(unsafe) var gKarabinerCLIPath: UnsafeMutablePointer<CChar>?
private nonisolated(unsafe) var gCrashProfileArgv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
private nonisolated(unsafe) var gCrashVariableArgv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
private nonisolated(unsafe) var gTermRequested: sig_atomic_t = 0

/// Async-signal-safe crash path: hand the keyboard back to the user's
/// Karabiner profile, then let the crash proceed to the default handler
/// (so launchd sees the crash and KeepAlive relaunches). posix_spawn and
/// raise are safe in handlers; everything else was prepared beforehand.
private func mardukCrashRestore(_ sig: Int32) {
    if let path = gKarabinerCLIPath {
        var pid: pid_t = 0
        if let argv = gCrashProfileArgv { posix_spawn(&pid, path, nil, nil, argv, nil) }
        if let argv = gCrashVariableArgv { posix_spawn(&pid, path, nil, nil, argv, nil) }
    }
    signal(sig, SIG_DFL)
    raise(sig)
}

enum MardukDaemon {
    /// Per-user, mode-0700 runtime directory (Darwin's /var/folders/…/T/).
    /// These paths used to live in world-writable /tmp, where any local
    /// user could drive the daemon over the socket — or pre-create the
    /// paths and block startup entirely (the sticky bit makes our unlink
    /// fail). The CLI and daemon share these constants, so both sides of
    /// the IPC move together.
    static let runtimeDir: String = {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count)
        var dir = (n > 0 && n <= buf.count) ? String(cString: buf) : NSTemporaryDirectory()
        if !dir.hasSuffix("/") { dir += "/" }
        // AF_UNIX sun_path caps at 104 bytes. Darwin temp dirs are ~50
        // chars, but if one is ever too long, fall back to the (also
        // per-user) config dir rather than producing a silently-truncated
        // path that the CLI and daemon would resolve differently.
        if dir.utf8.count + "marduk.sock".utf8.count >= 104 {
            dir = NSString(string: "~/.config/marduk/").expandingTildeInPath + "/"
            fputs("[marduk] temp dir too long for a socket — using \(dir)\n", stderr)
        }
        return dir
    }()
    static let socketPath = runtimeDir + "marduk.sock"
    static let pidPath = runtimeDir + "marduk.pid"
}

// MARK: - Client

enum DaemonClient {
    static var isRunning: Bool {
        send("ping")?.hasPrefix("OK") == true
    }

    @discardableResult
    static func send(_ command: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        // Never hang the CLI on a wedged daemon, and never die of SIGPIPE
        // if the daemon closes the socket mid-write.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        MardukDaemon.socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                UnsafeMutableRawPointer(dst).copyMemory(
                    from: src, byteCount: min(Int(strlen(src)) + 1, 104)
                )
            }
        }

        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { return nil }

        _ = command.withCString { Darwin.write(fd, $0, command.utf8.count) }
        shutdown(fd, SHUT_WR)

        // Read until EOF — a single read() is not guaranteed to return the
        // whole response on a stream socket.
        var data = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 65536 {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            data.append(contentsOf: buffer[0..<n])
        }
        guard !data.isEmpty else { return nil }
        return String(bytes: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Server

final class DaemonServer {
    private var serverFD: Int32 = -1
    private var running = false
    // Non-zero: exit with this code after cleanup so launchd's KeepAlive
    // (SuccessfulExit=false) relaunches us — the hot-update restart path.
    private var pendingExitCode: Int32 = 0
    private let ducker: AudioDucker
    private let speech: SpeechEngine
    private var signalSources: [DispatchSourceSignal] = []
    private var keyboardMonitor: KeyboardMonitor?
    private var displayInverter: DisplayInverter?
    // Boot-minimal after rapid crashes: risky subsystems skipped, update
    // train preserved (BootGuard)
    private var safeMode = false
    // nil while border and pointer dot are both off (the default);
    // ":config border/pointer on" creates and starts one live, turning
    // the last indicator off stops and releases it
    private var modeOverlay: ModeOverlay?
    private let escapeHoldThreshold: TimeInterval
    private let typingBurstThreshold: TimeInterval
    private let typingRescueEnabled: Bool

    // Retained for live mutation (":config") + persistence
    private var config: MardukConfig
    private let tutorial = Tutorial()
    private let onboarding: Onboarding
    private let dialogSentinel = DialogSentinel()
    // dialogfocus consent state (ask | always | off); markers make the
    // full pitch and the zoom pointer speak once ever (OnceMarker slugs
    // "dialogfocus-explained" / "zoomfollow-hinted")
    private var dialogFocusSetting: DialogFocus.Setting = .ask
    private let hoverSpeech = HoverSpeech()
    // First-run welcome deferred because the event tap didn't exist yet
    // (no Accessibility grant); spoken when the tap retry succeeds
    private var welcomePending = false
    private let palette = CommandPalette()
    private var paletteEnabled: Bool
    // Palette state, main-queue-only: last buffer + its completion candidates
    private var commandBufferSnapshot = ""
    private var commandCandidates: [CommandCompleter.Candidate] = []
    private var commandSelected = 0
    private var autoAcceptTimer: DispatchWorkItem?
    private var lastTipIndex = -1
    // Speed keys (Option+Up/Down): announce + persist once after the last
    // nudge, not per autorepeat event
    private var rateSaveTimer: DispatchWorkItem?
    // Read search: true when opening / or ? paused a SPEAKING read — the
    // cancel/no-match paths resume only then (a read the user had already
    // Space-paused before searching stays paused)
    private var searchPausedRead = false
    // Long-read chunking runs off-main; a newer read must win over a
    // stale chunk result landing late (R pressed twice on a huge doc).
    private var longReadGeneration = 0
    // Bumped on EVERY new read (onNewRead) — the async rich-text heading
    // harvest captures it at read start and drops stale deliveries
    private var readGeneration = 0

    // ":voices" picker rows: installed English voices, best quality first,
    // enumerated once on first use (same filter/sort as `marduk voices`)
    private lazy var voiceOptions: [(name: String, identifier: String)] = {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { a, b in
                if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
                return a.name < b.name
            }
            .map { v in
                let marker = v.quality == .premium ? " — premium"
                           : v.quality == .enhanced ? " — enhanced" : ""
                return (name: "\(v.name)\(marker)", identifier: v.identifier)
            }
    }()

    // Update checking: `u` checks + arms; a second u while armed installs.
    // The periodic timer announces once per new remote head (or installs,
    // with autoupdate on).
    private var updateArmedUntil: Date?
    // True whenever ANY check (periodic or manual) has seen updates and no
    // install has run since — the express uu consults this: a deliberate
    // uu after "updates exist" installs immediately, a stray uu on an
    // up-to-date system can only trigger a harmless check.
    private var updatesKnownAvailable = false
    private var lastAnnouncedRemote = ""
    private var lastAnnouncedRelease = ""  // release-channel dedup (tag, not sha)
    private var lastVerifyFailTag = ""     // failed-verification announce, once per tag
    private var autoRetryScheduled = false
    private var updateCheckTimer: DispatchSourceTimer?
    private var autoUpdate: Bool
    private var updateCheckHours: Int

    init(config: MardukConfig) {
        self.config = config
        onboarding = Onboarding(
            hintsEnabled: config.onboarding?.hints ?? true,
            hintsShown: config.onboarding?.hintsShown ?? 0,
            tutored: OnceMarker.seen("tutored"),
            lastHintAt: config.onboarding?.lastHintAt
                .map { Date(timeIntervalSince1970: $0) } ?? .distantPast)
        paletteEnabled = config.keyboard?.commandPalette ?? true
        autoUpdate = config.update?.auto ?? true
        updateCheckHours = config.update?.checkHours ?? 24
        escapeHoldThreshold = TimeInterval(config.keyboard?.escapeHoldMs ?? 400) / 1000.0
        typingBurstThreshold = TimeInterval(config.keyboard?.typingBurstMs ?? 300) / 1000.0
        typingRescueEnabled = config.keyboard?.typingRescue ?? true
        let duckerConfig = AudioDucker.Config(
            duckLevel: config.ducking.duckLevel,
            rampSteps: config.ducking.rampSteps,
            rampDurationMs: config.ducking.rampDurationMs,
            targets: buildDuckTargets(from: config),
            extraMediaKeyApps: config.ducking.mediaKeyApps ?? []
        )
        ducker = AudioDucker(config: duckerConfig)
        speech = SpeechEngine(ducker: ducker)
        speech.rate = config.speech.rate
        speech.pitch = config.speech.pitch ?? 1.0
        speech.preprocessor = SpeechPreprocessor.settings(from: config.verbalizer)

        if let voiceId = config.speech.voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: voiceId) {
            speech.voice = voice
        }

        displayInverter = DisplayInverter(invertApps: config.display.invertForApps)
        // OPT-IN: inversion fires keystrokes and Automation prompts —
        // never a surprise default (the built-in app list only matters
        // once the user says :config invert on)
        displayInverter?.invertEnabled = config.display.invertEnabled ?? false
        displayInverter?.pdfDarkStyle = DisplayInverter.PDFDarkStyle(
            rawValue: config.display.pdfDark ?? "") ?? .auto
        displayInverter?.autoInvert = config.display.autoInvert ?? false
        displayInverter?.autoInvertThreshold =
            Double(min(95, max(40, config.display.autoInvertThreshold ?? 70))) / 100.0
        modeOverlay = ModeOverlay(config: config.overlay ?? .init())
    }

    func run() throws {
        // Rapid-crash guard: at the threshold, boot minimal — speech,
        // socket, tap, updates — so a startup crash on some future macOS
        // can never lock users out of the fix (see BootGuard).
        let bootAttempt = BootGuard.register()
        safeMode = bootAttempt >= BootGuard.safeModeThreshold
        if safeMode {
            fputs("[marduk] SAFE MODE (boot attempt \(bootAttempt))\n", stderr)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            BootGuard.markStable()
        }

        // A client that disconnects before we write its response would
        // otherwise kill the whole daemon with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)

        let pid = ProcessInfo.processInfo.processIdentifier
        try "\(pid)".write(toFile: MardukDaemon.pidPath, atomically: true, encoding: .utf8)

        if unlink(MardukDaemon.socketPath) != 0 && errno != ENOENT {
            // Can't remove a pre-existing socket we don't own — surface the
            // real cause instead of the opaque EADDRINUSE bind would give
            throw NSError(domain: "marduk", code: 4, userInfo: [
                NSLocalizedDescriptionKey:
                    "Stale socket at \(MardukDaemon.socketPath) can't be removed (errno \(errno))"])
        }

        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw NSError(domain: "marduk", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create socket"])
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        MardukDaemon.socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                UnsafeMutableRawPointer(dst).copyMemory(
                    from: src, byteCount: min(Int(strlen(src)) + 1, 104)
                )
            }
        }

        let bindOK = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindOK == 0 else {
            close(serverFD)
            throw NSError(domain: "marduk", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to bind socket (errno \(errno))"])
        }
        // Owner-only, on top of the 0700 runtime dir — the socket carries
        // speak/stop/reload, none of another user's business
        chmod(MardukDaemon.socketPath, 0o600)

        guard Darwin.listen(serverFD, 5) == 0 else {
            close(serverFD)
            throw NSError(domain: "marduk", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to listen on socket"])
        }

        running = true
        setupSignalHandlers()

        // Accept connections on background thread
        DispatchQueue.global(qos: .utility).async { [self] in
            while running {
                let clientFD = accept(serverFD, nil, nil)
                guard clientFD >= 0 else {
                    if !running { break }
                    // Don't spin at 100% CPU if accept() fails persistently
                    usleep(100_000)
                    continue
                }
                guard running else { close(clientFD); break }
                handleClient(clientFD)
            }
        }

        // The command palette panel needs NSApplication initialized;
        // .accessory keeps us out of the Dock and app switcher. The existing
        // RunLoop below is enough — no NSApp.run() needed.
        _ = NSApplication.shared
        // Visible-app mode is opt-in: .regular puts Marduk in the Dock,
        // the app switcher, and the Force Quit window (macOS ties all
        // three to one policy — there is no Force-Quit-only state)
        NSApp.setActivationPolicy((config.display.dockIcon ?? false) ? .regular : .accessory)
        if !safeMode { modeOverlay?.start() }

        tutorial.announce = { [self] text in speech.announce(text) }
        // Finishing the guided tour is the strongest "this user gets it"
        // signal — feature hints stand down afterward.
        tutorial.onComplete = { [self] in onboarding.markTutored() }
        onboarding.speak = { [self] text in speech.announce(text) }
        onboarding.isSpeaking = { [self] in speech.isSpeaking }
        onboarding.persistProgress = { [self] count, at in
            var ob = config.onboarding ?? MardukConfig.OnboardingConfig()
            ob.hintsShown = count
            // Persisted so the multi-day cooldown survives restarts
            ob.lastHintAt = at.timeIntervalSince1970
            config.onboarding = ob
            ConfigLoader.save(config)
        }

        // Dialog sentinel: password prompts, permission dialogs, and
        // in-app sheets are invisible to a zoomed-in user — announce
        // them (interrupting reads on purpose; a dialog IS urgent), and
        // per the dialogfocus consent the announcement can carry the
        // a/o/n/s question or trigger a silent focus (handleDialogAnnouncement)
        dialogSentinel.announce = { [self] text, target in
            handleDialogAnnouncement(text, target: target)
        }
        // dialogLevel wins; legacy dialogAlerts=false maps to off
        dialogSentinel.level = DialogSentinel.Level(
            rawValue: config.keyboard?.dialogLevel ?? "")
            ?? ((config.keyboard?.dialogAlerts ?? true) ? .all : .off)
        dialogFocusSetting = DialogFocus.Setting(
            rawValue: config.keyboard?.dialogFocus ?? "") ?? .ask
        if !safeMode { dialogSentinel.start() }

        // One-time onboarding: automatic dark PDFs are an invisible
        // automation — the first success explains itself, once ever
        displayInverter?.onDarkApplied = { [self] in
            guard OnceMarker.firstTime("pdfdark-noticed") else { return }
            speech.announce("Preview switched this P D F to dark view, "
                + "matching your dark system theme. This happens "
                + "automatically. Say colon config p d f dark off to stop.")
        }
        // A denied Automation grant makes every inversion a silent no-op —
        // say so and put the user in the right pane (field 2026-07-22:
        // discovered as "the screen stayed bright"; the hint had only
        // been logged)
        displayInverter?.onAutomationDenied = { [self] in
            speech.announce("Marduk lost permission to control System Events, "
                + "so display inversion can't work. Opening Automation "
                + "settings — find Marduk and turn System Events back on.")
            openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        }

        // Visual follow: the app's view tracks the read. Page jumps drive
        // the viewer's go-to-page gesture (Preview); web reads scroll the
        // contributing element into view as the voice crosses paragraphs.
        keyboardMonitor?.followEnabled = config.keyboard?.follow ?? true
        speech.onNewRead = { [self] in
            readGeneration += 1  // async heading harvests drop stale results
            keyboardMonitor?.clearWebReadAnchors()
            // Asking for a NEW read means "I want to listen" — reclaim the
            // capture even when the previous read was still playing under
            // an i-suspended INSERT (no readActive edge fires then)
            keyboardMonitor?.readStateChanged(true)
        }
        speech.onPositionChange = { [self] offset in
            guard let snapshot = speech.readSnapshot else { return }
            keyboardMonitor?.followScroll(offset: offset, text: snapshot.text)
        }
        speech.onPageJump = { [self] page in
            guard keyboardMonitor?.followEnabled == true,
                  let bundle = keyboardMonitor?.frontmostApp else { return }
            guard let chord = KeyboardMonitor.pageChords[bundle] else {
                fputs("[keyboard] follow: no go-to-page gesture for \(bundle)\n", stderr)
                return
            }
            // Our own Go-to-Page sheet must not be announced as a dialog
            dialogSentinel.suppress(for: 3)
            keyboardMonitor?.postGoToPage(page, chord: chord)
        }

        // Pointer hover speech — Marduk's own, in the reading voice
        hoverSpeech.speak = { [self] text in speech.hover(text) }
        hoverSpeech.announce = { [self] text in speech.announce(text) }

        // Start keyboard monitor (Option+Escape → speak selection)
        keyboardMonitor = KeyboardMonitor()
        keyboardMonitor?.escapeHoldThreshold = escapeHoldThreshold
        keyboardMonitor?.typingBurstThreshold = typingBurstThreshold
        keyboardMonitor?.typingRescueEnabled = typingRescueEnabled
        keyboardMonitor?.typingEchoEnabled = config.keyboard?.typingEcho ?? false
        keyboardMonitor?.commandEchoEnabled = config.keyboard?.commandEcho ?? true
        keyboardMonitor?.speedKeysEnabled = config.keyboard?.speedKeys ?? false
        keyboardMonitor?.readMotionsEnabled = config.keyboard?.readMotions ?? true
        keyboardMonitor?.onHoverToggle = { [self] in hoverSpeech.toggle() }
        keyboardMonitor?.toggleEarconEnabled =
            (config.keyboard?.toggleSound ?? "speech") == "earcon"
        palette.positionMode = CommandPalette.PositionMode(
            rawValue: config.keyboard?.palettePosition ?? "pointer") ?? .pointer
        // Tutorial events ride the existing callbacks: reads complete via the
        // per-utterance completion, announcements and pause toggles are
        // interposed here. The tutorial's own narration goes straight to
        // speech.announce (tutorial.announce above), so it never sees itself.
        keyboardMonitor?.start(
            onSpeak: { [self] text in
                longReadGeneration += 1  // a new read beats an in-flight chunk
                startingRead(paged: false) { [self] in
                    speech.speak(text) { [self] in contentReadEnded() }
                }
            },
            onStop: { [self] in
                longReadGeneration += 1  // a stop beats an in-flight chunk
                speech.stop()
            },
            onAnnounce: { [self] text in
                tutorial.handle(.announced(text))
                speech.announce(text)
            },
            onUpdate: { [self] in handleFastUpdateKey() },
            isSpeaking: { [self] in speech.isSpeaking },
            isReadActive: { [self] in speech.readActive },
            isReadPaused: { [self] in speech.isPaused },
            onPauseToggle: { [self] in
                tutorial.handle(.pauseToggled)
                speech.togglePause()
            }
        )
        // didSet observers fire synchronously inside the tap callback — hop
        // to main before touching the tutorial or the palette.
        keyboardMonitor?.onModeChange = { [self] mode in
            DispatchQueue.main.async { [self] in
                tutorial.handle(.mode(mode))
                modeOverlay?.setMode(mode)
                if mode != .command {
                    palette.hide()
                    autoAcceptTimer?.cancel()
                }
            }
        }
        keyboardMonitor?.onReadingChange = { [self] reading in
            DispatchQueue.main.async { [self] in modeOverlay?.setReading(reading) }
        }
        keyboardMonitor?.onEnabledChange = { [self] enabled in
            DispatchQueue.main.async { [self] in
                modeOverlay?.setEnabled(enabled)
                // Ctrl+Option+M = the whole Karabiner story flips: profile
                // AND liveness variable, so the user never switches by hand
                Self.setKarabinerVariable(up: enabled)
                if enabled {
                    activateKarabinerProfile()
                } else {
                    deactivateKarabinerProfile()
                }
                if !enabled {
                    tutorial.abort(silent: true)
                    palette.hide()
                    hoverSpeech.deactivate()
                    // "Systems disengaged" must mean ALL systems: the
                    // sentinel's toggle gating was lost in the level
                    // migration and the inverter was never wired (field:
                    // a disengaged Marduk kept announcing dialogs and
                    // inverting displays). stop() also reverts any active
                    // inversion — teardown code reused as stand-down.
                    dialogSentinel.stop()
                    displayInverter?.stop()
                } else if !safeMode {
                    dialogSentinel.start()
                    displayInverter?.start()
                }
            }
        }
        speech.frontmostAppProvider = { [self] in keyboardMonitor?.frontmostApp }
        KeyboardMonitor.onAXRevoked = { [self] in
            Earcon.error()  // audible even if the synthesizer is also down
            fputs("[marduk] Accessibility permission revoked (kAXErrorAPIDisabled) "
                + "— remove and re-add Marduk.app in Privacy & Security\n", stderr)
            speech.announce("Marduk's Accessibility permission looks broken — "
                + "this can happen after an update. In the Settings pane I'm "
                + "opening, remove Marduk from the list, then add Marduk dot "
                + "app again. Toggling it is not enough.")
            let opener = Process()
            opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            opener.arguments = ["x-apple.systempreferences:"
                + "com.apple.preference.security?Privacy_Accessibility"]
            try? opener.run()
        }
        keyboardMonitor?.onCommandSubmit = { [self] raw in handleColonCommand(raw) }
        keyboardMonitor?.onCommandChange = { [self] buffer, canAutoAccept in
            handleCommandChange(buffer, canAutoAccept: canAutoAccept)
        }
        keyboardMonitor?.onCommandTab = { [self] in handleCommandTab() }
        keyboardMonitor?.onCommandSelect = { [self] delta in handleCommandSelect(delta) }
        keyboardMonitor?.onCommandHelp = { [self] in speakCommandOptions(explicit: true) }
        keyboardMonitor?.onCommandIdle = { [self] in speakCommandOptions(explicit: false) }
        keyboardMonitor?.onUpdateCheck = { [self] in handleUpdateKey() }
        // dd — cut a patch release. The gesture only exists on a source
        // install; elsewhere the flag stays false and d remains a plain
        // letter (typing rescue untouched — zero surface for strangers).
        keyboardMonitor?.releaseAvailable = projectDir != nil
        keyboardMonitor?.onCutRelease = { [self] in handleReleaseKey() }
        // Speed keys: rate applies instantly per nudge; the announcement
        // and the config write debounce until the key is released, so a
        // held autorepeat doesn't spam speech or disk. (Arrives on main.)
        keyboardMonitor?.onRateChange = { [self] delta in
            speech.adjustRate(delta: delta)
            rateSaveTimer?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let wpm = Int(self.speech.rate * 360)
                self.config.speech.rate = self.speech.rate
                ConfigLoader.save(self.config)
                // READ voice on purpose: the confirmation demos the new rate
                self.speech.speak("\(wpm) words per minute.")
            }
            rateSaveTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        // READING capture: the engine's readActive flips drive the keyboard's
        // modal reading state, synchronously (speak() and the AV delegate
        // both run on main) — a read can never be active without its capture
        speech.onReadActiveChange = { [weak self] active in
            self?.keyboardMonitor?.readStateChanged(active)
        }
        // Read motions: all handlers arrive on main (the monitor dispatches).
        // The buzz on an unmoved jump keeps edges audible — silence after a
        // keypress would read as a broken key.
        keyboardMonitor?.onReadJump = { [self] unit, direction, count in
            if speech.jump(unit, direction: direction, count: count) {
                tutorial.handle(.readJumped)
            } else {
                Earcon.error()
            }
        }
        keyboardMonitor?.onReadJumpEdge = { [self] direction in
            // On a paged read, G means "last page", not "last paragraph"
            let jumped = direction == .forward && speech.isPaged
                ? speech.jumpToPage(speech.pageCount)
                : speech.jumpToEdge(direction)
            if jumped {
                tutorial.handle(.readJumped)
            } else {
                Earcon.error()
            }
        }
        keyboardMonitor?.onReadPageStep = { [self] step in
            if speech.jumpPage(step: step) {
                tutorial.handle(.readJumped)
            } else {
                Earcon.error()
            }
        }
        keyboardMonitor?.onReadPageAbsolute = { [self] page in
            if speech.jumpToPage(page) {
                tutorial.handle(.readJumped)
            } else {
                Earcon.error()
            }
        }
        keyboardMonitor?.onReadPercent = { [self] percent in
            if speech.jumpToPercent(percent) {
                tutorial.handle(.readJumped)
            } else {
                Earcon.error()
            }
        }
        keyboardMonitor?.onReadPosition = { [self] in
            if !speech.speakPosition() {
                Earcon.error()
            }
        }
        keyboardMonitor?.onSpeakPaged = { [self] paged, startPage, headings in
            longReadGeneration += 1  // a new read beats an in-flight chunk
            startingRead(paged: true) { [self] in
                speech.speakPaged(paged, startPage: startPage,
                                  headings: headings) { [self] in
                    contentReadEnded()
                }
            }
        }
        keyboardMonitor?.onSpeakDocument = { [self] text, start in
            speakDocument(text, start: start)
        }
        keyboardMonitor?.onReadLineStart = { [self] in
            if !speech.jumpToLineStart() {
                Earcon.error()
            }
        }
        keyboardMonitor?.onReadSpell = { [self] unit in
            if speech.spell(unit) {
                tutorial.handle(.spelled)
            } else {
                Earcon.error()
            }
        }
        keyboardMonitor?.onReadFind = { [self] char, direction in
            if !speech.findChar(char, direction: direction) {
                Earcon.error()
            }
        }
        keyboardMonitor?.onReadHeading = { [self] motion, count in
            if speech.jumpHeading(motion, count: count) {
                tutorial.handle(.readJumped)
            } else {
                Earcon.error()
            }
        }
        keyboardMonitor?.onHarvestHeadings = { [self] lines in
            speech.setReadHeadings(lines: lines)
        }
        keyboardMonitor?.readGenerationProvider = { [self] in readGeneration }
        keyboardMonitor?.onReadSearchBegin = { [self] in
            if speech.isSpeaking, !speech.isPaused {
                speech.pause()
                searchPausedRead = true
            } else {
                searchPausedRead = false
            }
        }
        keyboardMonitor?.onReadSearchCancel = { [self] in
            if searchPausedRead { speech.resume() }
            searchPausedRead = false
        }
        keyboardMonitor?.onReadSearch = { [self] query, direction in
            let paused = searchPausedRead
            searchPausedRead = false
            guard let snapshot = speech.readSnapshot,
                  let target = ReadNavigator.searchTarget(
                      in: snapshot.text, from: snapshot.position,
                      query: query, direction: direction) else {
                Earcon.error()
                if paused { speech.resume() }
                return
            }
            speech.jumpTo(offset: target) // respeak = auto-resume
        }
        // Echo over the paused read — announce() would stop() it
        keyboardMonitor?.onReadSearchEcho = { [self] text in speech.echo(text) }
        // Firefox Reader narration handoff (`n`): Marduk gets out of the
        // way — hold FIRST so the speech cancel's unduck lands blocked,
        // then stop our speech and pause media. The hold keeps media
        // paused across any announcements until narration ends.
        keyboardMonitor?.onNarrate = { [self] active in
            if active {
                ducker.holdDucking()
                speech.stop()
                ducker.prepareToDuck()
                ducker.duck()
            } else {
                ducker.releaseHoldAndUnduck()
            }
        }
        // Clicking a palette row acts like Tab on that row (mouseDown arrives
        // on the main thread already)
        palette.onRowClick = { [self] row in
            guard commandCandidates.indices.contains(row) else { return }
            commandSelected = row
            handleCommandTab()
        }
        scheduleUpdateChecks()

        if !safeMode { displayInverter?.start() }

        // First-run welcome — but ONLY once the event tap exists. On the
        // canonical fresh install there is no Accessibility grant yet: the
        // welcome would end "press t, p, or s" with no tap to capture the
        // answer (keys fall through to the frontmost app) and the consumed
        // marker meant the orientation never replayed (field-audited gap).
        // The marker is consumed at SPEAK time, so an ungranted install
        // keeps its welcome for the retry — or the next daemon start.
        keyboardMonitor?.onTapEstablished = { [self] in
            if welcomePending {
                welcomePending = false
                runFirstRunWelcome()  // the welcome IS the "keyboard works" feedback
            } else {
                speech.announce("Keyboard commands active.")
            }
        }
        if !OnceMarker.seen("welcomed") {
            if keyboardMonitor?.tapAlive == true {
                runFirstRunWelcome()
            } else {
                welcomePending = true
                fputs("[marduk] first-run welcome deferred until tap exists\n", stderr)
            }
        }

        fputs("[marduk] Daemon running (PID \(pid))\n", stderr)
        fputs("[marduk] Socket: \(MardukDaemon.socketPath)\n", stderr)
        Self.setKarabinerVariable(up: true)
        activateKarabinerProfile()
        announceKarabinerAbsenceOnce()
        announceUntestedMacOSOnce()
        if safeMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [self] in
                speech.announce("Marduk started in safe mode after repeated "
                    + "crashes. Reading and updates work; extras are off. An "
                    + "update may fix this — press u to check. Colon restart "
                    + "tries a full start.")
            }
        }

        // SIGTERM (logout, launchctl bootout) → flag polled by the loop →
        // FULL clean teardown, Karabiner profile included. Signal handlers
        // can only touch a flag safely; the loop below does the real work.
        signal(SIGTERM) { _ in gTermRequested = 1 }

        // Main RunLoop — needed for AVSpeechSynthesizer + CGEventTap callbacks
        while running {
            if gTermRequested != 0 {
                fputs("[marduk] SIGTERM — clean shutdown\n", stderr)
                running = false
                break
            }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }

        // Stop event tap first to prevent callbacks during teardown
        Self.setKarabinerVariable(up: false)
        deactivateKarabinerProfile()
        dialogSentinel.stop()
        hoverSpeech.deactivate()
        keyboardMonitor?.stop()
        // Drain pending callbacks
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        cleanup()
        if pendingExitCode != 0 {
            exit(pendingExitCode)
        }
    }

    // MARK: - Long reads

    /// Full-document read: plain when it fits one page window, else chunk
    /// into synthetic pages OFF-MAIN (chunking a multi-MB string on main
    /// would recreate the event-tap freeze the input cap fixed) and ride
    /// the paged machinery — every part of any size document reachable
    /// while preprocessing stays bounded. `start` is the exact UTF-16
    /// offset the voice begins at; on paged reads the text before it
    /// stays reachable (gg = the true top).
    private func speakDocument(_ text: String, start: Int) {
        longReadGeneration += 1
        let ns = text as NSString
        guard PagedText.exceedsWindow(ns.length) else {
            startingRead(paged: false) { [self] in
                speech.speak(ns.substring(from: max(0, min(start, ns.length)))) { [self] in
                    contentReadEnded()
                }
            }
            return
        }
        fputs("[speech] long read (\(ns.length) chars) — chunking into "
            + "synthetic pages\n", stderr)
        let generation = longReadGeneration
        DispatchQueue.global(qos: .utility).async { [self] in
            let (paged, startPage) = PagedText.chunking(text, from: start)
            DispatchQueue.main.async { [self] in
                guard generation == longReadGeneration else { return }
                fputs("[speech] long read chunked: \(paged.pageCount) pages\n", stderr)
                startingRead(paged: true) { [self] in
                    speech.speakPaged(paged, startPage: startPage,
                                      synthetic: true) { [self] in
                        contentReadEnded()
                    }
                }
            }
        }
    }

    /// Speak a farewell, then run the exit action on main — but never let a
    /// wedged synthesizer strand the daemon. `:quit`/`:restart` used to set
    /// their exit state ONLY inside the announcement completion, and the
    /// speech-health watchdog covers reads (`readText != nil`), never
    /// announcements: an utterance accepted but never started meant the
    /// daemon simply never stopped. Completion or deadline, first one wins,
    /// exactly once (both arrive on main, so the flag needs no lock).
    private func announceThenExit(_ text: String,
                                  _ exitAction: @escaping () -> Void) {
        var fired = false
        let once: () -> Void = {
            guard !fired else { return }
            fired = true
            exitAction()
        }
        speech.announce(text) {
            DispatchQueue.main.async { once() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if !fired { fputs("[marduk] exit announcement wedged — "
                + "exiting anyway\n", stderr) }
            once()
        }
    }

    /// Every content read routes its completion here: the tutorial event
    /// first, then the progressive feature hints. A read's END is the one
    /// reliably QUIET moment (offer's isSpeaking gate makes mid-read
    /// moments ineligible — a paused synthesizer still reports speaking),
    /// so the reading-family hints all queue here in priority order; the
    /// engine's cooldown lets at most one surface per read end, spacing
    /// the rest across future reads. Never during the tutorial — the tour
    /// is already teaching.
    private func contentReadEnded() {
        tutorial.handle(.readFinished)
    }

    /// Speak a hint about reading BEFORE the read it describes, then run
    /// the read. A tip has to arrive attached to the thing it's about —
    /// arriving in the silence after a read is out of the blue, and by
    /// then the moment it would have helped with has passed (user ruling
    /// 2026-07-22). Nothing eligible = the read starts immediately, so
    /// the common path is untouched.
    ///
    /// Order matters: the most useful tip for THIS read wins, and the
    /// engine's cooldown keeps the rest for later reads.
    private func startingRead(paged: Bool, then read: @escaping () -> Void) {
        guard !tutorial.isActive else { return read() }
        // Every caller bumps this before us. If a NEWER read starts while
        // the tip is speaking, that read cancels the tip — whose completion
        // still fires — and running our read then would clobber the one the
        // user actually just asked for.
        let generation = longReadGeneration
        guard let tip = onboarding.claim(paged ? .pagedReadStart : .readStart) else {
            return read()
        }
        speech.announce(tip) { [self] in
            DispatchQueue.main.async { [self] in
                guard generation == longReadGeneration else {
                    fputs("[onboarding] newer read won — dropping the "
                        + "tipped one\n", stderr)
                    return
                }
                read()
            }
        }
    }

    // MARK: - Dialog focus (consent-gated)

    /// Every sentinel announcement routes here. Focusing a dialog is
    /// input-invasive, so it never happens without consent: `always`
    /// focuses silently, `off` never does, and `ask` rides the a/o/n/s
    /// question on the announcement — full pitch once ever, terse after.
    /// Zoom's Follow keyboard focus is a SIGNAL for wording (synergy
    /// line when on, one-time Settings pointer when not), never a gate.
    private func handleDialogAnnouncement(_ text: String,
                                          target: DialogSentinel.Target?) {
        guard let target, dialogFocusSetting != .off else {
            speech.announce(text)  // announcements always continue
            return
        }
        if dialogFocusSetting == .always {
            speech.announce(text)  // announcement unchanged — silent focus
            focusDialog(target)
            return
        }
        let explained = OnceMarker.seen("dialogfocus-explained")
        let zoomFollows = DialogFocus.zoomFollowsFocus()
        guard let tail = DialogFocus.promptTail(
            setting: .ask, explained: explained,
            zoomFollowsFocus: zoomFollows) else {
            speech.announce(text)
            return
        }
        if !explained { OnceMarker.mark("dialogfocus-explained") }
        // The window restarts when the spoken question ENDS — listening
        // to the full pitch must never eat the answer time
        speech.announce(text + " " + tail) { [weak keyboardMonitor] in
            keyboardMonitor?.extendQuestionWindow()
        }
        keyboardMonitor?.armQuestion(keys: ["a", "o", "n", "s"]) { [self] answer in
            guard let resolution = DialogFocus.resolve(answer: answer) else { return }
            if let setting = resolution.newSetting { setDialogFocus(setting) }
            speech.announce(resolution.ack)
            guard resolution.focusNow else { return }
            focusDialog(target)
            // The moment the pointer is relevant: their first focused
            // dialog only zooms into view if zoom follows focus
            if let hint = DialogFocus.zoomHint(zoomFollowsFocus: zoomFollows),
               OnceMarker.firstTime("zoomfollow-hinted") {
                speech.announce(hint)
            }
        }
    }

    /// Speak the first-run orientation and arm the t/p/s choice. Caller
    /// guarantees the event tap is alive (the choice needs it). The marker
    /// is written just before speaking — a crash mid-speech can never
    /// replay-loop the welcome, but a tap-less boot never consumes it.
    private func runFirstRunWelcome() {
        DispatchQueue.main.async { [self] in
            OnceMarker.mark("welcomed")
            fputs("[marduk] first-run welcome\n", stderr)
            // Arm the t/p/s learning-mode choice only AFTER the welcome
            // finishes reading (the welcome IS a read — reading capture
            // holds the keyboard until it ends — so arming earlier would
            // fight it, and the window would tick during the long pitch).
            speech.speak(HelpText.welcome) { [self] in
                keyboardMonitor?.armQuestion(keys: ["t", "p", "s"]) { [self] answer in
                    handleWelcomeChoice(answer)
                }
            }
        }
    }

    /// First-run learning-mode choice (t/p/s). Escape / timeout / any
    /// other key leaves progressive hints ON — the respectful default.
    private func handleWelcomeChoice(_ answer: Character) {
        switch answer {
        case "t":
            fputs("[onboarding] welcome choice: tutorial\n", stderr)
            tutorial.start()
        case "p":
            fputs("[onboarding] welcome choice: progressive\n", stderr)
            setHints(true)
            speech.announce("Good. I will point out features as they come up. "
                + "Say colon hints off any time.")
        case "s":
            fputs("[onboarding] welcome choice: on my own\n", stderr)
            setHints(false)
            speech.announce("Okay, you are on your own. Say colon tutorial or "
                + "colon hints on whenever you like.")
        default:
            break
        }
    }

    private func setHints(_ on: Bool) {
        onboarding.hintsEnabled = on
        var ob = config.onboarding ?? MardukConfig.OnboardingConfig()
        ob.hints = on
        config.onboarding = ob
        ConfigLoader.save(config)
    }

    private func setDialogFocus(_ setting: DialogFocus.Setting) {
        dialogFocusSetting = setting
        var kb = config.keyboard ?? MardukConfig.KeyboardConfig()
        kb.dialogFocus = setting.rawValue
        config.keyboard = kb
        ConfigLoader.save(config)
    }

    /// Bring the announced dialog to the front AND give it keyboard focus
    /// — a plain z-order raise isn't enough for the prompts that need this
    /// most: permission dialogs (Allow/Don't Allow, no text field) never
    /// take focus themselves, so `AXRaise` "succeeds" while the window
    /// server keeps the previous app on top and zoom (which follows the
    /// FOCUSED element) has nothing to pan to (field: raise ok, but front
    /// stayed Terminal). So we also set the app frontmost and the window
    /// main+focused. Detector-2 targets carry the element; detector-1
    /// (system agents) is PID-only — resolve the dialog window now. No
    /// dismissal observer by design: an AX read error = the dialog closed
    /// between announce and answer. Best-effort, 0.5s timeouts, error
    /// codes only in the log — never titles.
    private func focusDialog(_ target: DialogSentinel.Target) {
        let window: AXUIElement
        if let element = target.element {
            AXUIElementSetMessagingTimeout(element, 0.5)
            var roleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString,
                                                &roleRef) == .success else {
                fputs("[sentinel] focus: dialog element gone\n", stderr)
                Earcon.error()
                speech.announce("That dialog is gone.")
                return
            }
            window = element
        } else if let resolved = dialogWindow(pid: target.pid) {
            window = resolved
        } else {
            fputs("[sentinel] focus: no window to focus\n", stderr)
            NSRunningApplication(processIdentifier: target.pid)?.activate()
            return
        }
        bringDialogForward(window: window, pid: target.pid)
    }

    /// A system agent's dialog window: prefer an AXDialog/AXSystemDialog
    /// subrole (the prompt), else the focused window, else the first.
    private func dialogWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString,
                                            &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
            fputs("[sentinel] focus: agent exposes no windows\n", stderr)
            return nil
        }
        fputs("[sentinel] focus: agent has \(windows.count) window(s)\n", stderr)
        for w in windows {
            var subRef: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &subRef)
            if let sub = subRef as? String,
               sub == "AXDialog" || sub == "AXSystemDialog" { return w }
        }
        return windows.first
    }

    private func bringDialogForward(window: AXUIElement, pid: pid_t) {
        func ok(_ e: AXError) -> String { e == .success ? "ok" : "err\(e.rawValue)" }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        // App frontmost first (a bare .activate() doesn't always take on a
        // system agent), then make the dialog the main + FOCUSED window and
        // raise it. Raise last to settle z-order.
        let front = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString,
                                                 kCFBooleanTrue)
        let main = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString,
                                                kCFBooleanTrue)
        let focused = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString,
                                                   kCFBooleanTrue)
        let raise = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate()
        fputs("[sentinel] focus: frontmost=\(ok(front)) main=\(ok(main)) "
            + "focused=\(ok(focused)) raise=\(ok(raise))\n", stderr)
        // Hands-off pan attempt: follow-keyboard-focus zoom tracks a
        // focused ELEMENT change — setting the WINDOW focused didn't pan
        // (field: focused=ok, no pan), but a focused button fires the
        // kAXFocusedUIElementChanged the zoom mode actually watches. If it
        // works, the view moves with no mouse nudge.
        if let button = dialogButton(window) {
            let bf = AXUIElementSetAttributeValue(button, kAXFocusedAttribute as CFString,
                                                  kCFBooleanTrue)
            fputs("[sentinel] focus: dialog button focused=\(ok(bf))\n", stderr)
        } else {
            fputs("[sentinel] focus: no button to focus\n", stderr)
        }
        warpPointerToDialog(window)
    }

    /// A focusable button in the dialog: the default button if exposed,
    /// else the first AXButton among the window's children.
    private func dialogButton(_ window: AXUIElement) -> AXUIElement? {
        var defRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXDefaultButtonAttribute as CFString,
                                         &defRef) == .success,
           let def = defRef, CFGetTypeID(def) == AXUIElementGetTypeID() {
            return (def as! AXUIElement)
        }
        var kidsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString,
                                            &kidsRef) == .success,
              let kids = kidsRef as? [AXUIElement] else { return nil }
        for child in kids {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            if roleRef as? String == "AXButton" { return child }
        }
        return nil
    }

    /// Pan a zoomed viewport to the dialog by moving the POINTER onto it.
    /// Zoom reliably tracks the pointer (Marduk's zoom-proof lesson —
    /// follow-keyboard-focus ignores our programmatic focus: field showed
    /// focused=ok with no pan), and landing the cursor on the dialog also
    /// puts it where the user must click. Warps to the window CENTER (the
    /// message area, not a button — a stray click there does nothing).
    private func warpPointerToDialog(_ window: AXUIElement) {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString,
                                            &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString,
                                            &sizeRef) == .success,
              let posVal = posRef, let sizeVal = sizeRef,
              CFGetTypeID(posVal) == AXValueGetTypeID(),
              CFGetTypeID(sizeVal) == AXValueGetTypeID() else {
            fputs("[sentinel] focus: no window frame for pointer warp\n", stderr)
            return
        }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
        // Warp the cursor onto the dialog. This does NOT pan zoom on its
        // own — zoom pans only on real HARDWARE pointer deltas (synthetic
        // .mouseMoved confirmed useless, field 2026-07-22, matching the
        // palette's own note) — but it lands the cursor at the dialog so
        // the user's next tiny nudge pans to the RIGHT place, with the
        // cursor already on the dialog to click Allow/Don't Allow.
        CGWarpMouseCursorPosition(center)
        fputs("[sentinel] focus: pointer warped to dialog center\n", stderr)
    }

    // MARK: - Client Handling

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }

        // Same-user only. The socket path is 0600 inside a 0700 dir, but
        // permissions are policy and credentials are proof — verify the
        // peer before reading a byte.
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        if getpeereid(fd, &peerUID, &peerGID) != 0 || peerUID != getuid() {
            fputs("[marduk] rejected socket connection from uid \(peerUID)\n", stderr)
            return
        }

        // A stalled or dead peer must never wedge the accept loop: bound every
        // socket operation and suppress SIGPIPE on write to a closed peer.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        // Read until EOF (the client shuts down its write side) so long
        // commands split across multiple reads aren't truncated.
        var data = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while data.count < 65536 {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            data.append(contentsOf: buffer[0..<n])
        }
        guard !data.isEmpty else { return }

        let command = String(bytes: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let response = processCommand(command)
        _ = response.withCString { Darwin.write(fd, $0, response.utf8.count) }
    }

    private func processCommand(_ raw: String) -> String {
        let parts = raw.split(separator: " ", maxSplits: 1)
        let cmd = parts.first.map(String.init) ?? ""
        let arg = parts.count > 1 ? String(parts[1]) : ""

        // Never log speak's payload — it's user content (the log is built
        // to be pasted into public issues via :log copy). Length only.
        // Other verbs carry settings vocabulary, useful for debugging.
        fputs("[marduk] cmd: \(cmd)", stderr)
        if !arg.isEmpty {
            if cmd == "speak" {
                fputs(" (\(arg.count) chars)", stderr)
            } else {
                fputs(" \(arg.prefix(80))", stderr)
            }
        }
        fputs("\n", stderr)

        switch cmd {
        case "ping":
            return safeMode ? "OK pong safe\n" : "OK pong\n"
        case "speak":
            guard !arg.isEmpty else { return "ERR no text\n" }
            DispatchQueue.main.async { [self] in speech.speak(arg) }
            return "OK\n"
        case "stop-speaking":
            DispatchQueue.main.async { [self] in speech.stop() }
            return "OK\n"
        case "duck":
            ducker.duck()
            return "OK\n"
        case "unduck":
            ducker.unduck()
            return "OK\n"
        case "rate":
            guard let val = Float(arg) else { return "ERR usage: rate <0.0-1.0>\n" }
            let clamped = max(0.0, min(1.0, val))
            DispatchQueue.main.async { [self] in speech.rate = clamped }
            let wpm = Int(clamped * 360)
            fputs("[marduk] Rate set to \(String(format: "%.2f", clamped)) (~\(wpm) WPM)\n", stderr)
            return "OK \(String(format: "%.2f", clamped)) (~\(wpm) WPM)\n"
        case "stop":
            DispatchQueue.main.async { [self] in running = false }
            return "OK stopping\n"
        case "reload":
            // Clean shutdown — marduk update will restart us
            DispatchQueue.main.async { [self] in running = false }
            return "OK reloading\n"
        default:
            return "ERR unknown: \(cmd)\n"
        }
    }

    // MARK: - ":" Commands (all on main queue)

    private func handleColonCommand(_ raw: String) {
        fputs("[command] \(raw)\n", stderr)

        // Fuzzy-search accept: run or expand the selected candidate
        if raw.hasPrefix("/") {
            guard commandCandidates.indices.contains(commandSelected),
                  let completion = commandCandidates[commandSelected].completion else {
                Earcon.error()
                speech.announce("No match.")
                return
            }
            if completion.hasSuffix(" ") {
                // A config key — keep typing the value
                speech.announce(completion.trimmingCharacters(in: .whitespaces))
                keyboardMonitor?.replaceCommandBuffer(completion)
            } else if let picker = ColonCommand.pickerCommands.first(where: {
                completion.hasPrefix("\($0) ")
            }) {
                // A picker row surfaced by "/" — apply directly (recursing
                // into handleColonCommand would re-read the selection and
                // loop)
                keyboardMonitor?.endCommandMode()
                applyPickerRow(picker,
                               identifier: String(completion.dropFirst(picker.count + 1)))
            } else {
                keyboardMonitor?.endCommandMode()
                handleColonCommand(completion)
            }
            return
        }

        // Staged picker accept — Return takes the highlighted row, dmenu
        // style (the tap keeps COMMAND mode alive for these, like "/").
        if let picker = ColonCommand.pickerCommands.first(where: { raw.hasPrefix($0) }) {
            // A buffer holding a full identifier (Tab/click filled it) is
            // already a decision — apply it without consulting the selection.
            // Identifiers are reverse-DNS; typed filter text can't contain
            // dots (the tap has no "." key in commandKeyChars).
            let arg = raw.dropFirst(picker.count).trimmingCharacters(in: .whitespaces)
            if arg.contains(".") {
                keyboardMonitor?.endCommandMode()
                applyPickerRow(picker, identifier: arg)
                return
            }
            guard commandCandidates.indices.contains(commandSelected),
                  let completion = commandCandidates[commandSelected].completion else {
                Earcon.error()
                speech.announce("No match.")
                return
            }
            if completion.hasSuffix(" ") {
                // The command row itself — enter the picker
                announcePickerEntry(picker)
                keyboardMonitor?.replaceCommandBuffer(completion)
            } else if completion.hasPrefix("\(picker) ") {
                keyboardMonitor?.endCommandMode()
                applyPickerRow(picker,
                               identifier: String(completion.dropFirst(picker.count + 1)))
            } else {
                // Selection drifted off the picker (shouldn't happen)
                Earcon.error()
                speech.announce("No match.")
            }
            return
        }

        switch ColonCommand.parse(raw) {
        case .help:
            speech.speak(HelpText.help)
        case .commands:
            speech.speak(HelpText.commands)
        case .tutorial:
            if tutorial.isActive {
                tutorial.abort(silent: false)
            } else {
                tutorial.start()
            }
        case .tip:
            var index = Int.random(in: 0..<HelpText.tips.count)
            if HelpText.tips.count > 1 && index == lastTipIndex {
                index = (index + 1) % HelpText.tips.count
            }
            lastTipIndex = index
            speech.speak("Tip: " + HelpText.tips[index])
        case .voices, .invertApps:
            // Unreachable in practice — every picker-prefixed buffer is
            // intercepted above before parse. Compiler exhaustiveness only.
            break
        case .typing:
            // One-stop shop: macOS already speaks keys/words as you type,
            // system-wide — route the seeker to the real switch instead of
            // reinventing it, and name Marduk's own in-house echo too
            speech.announce("Opening Read and Speak Content in System "
                + "Settings. Turn on typing feedback there to hear characters "
                + "and words spoken as you type, in every app. Separately, "
                + "colon config echo on makes Marduk speak keys typed in its "
                + "own command panel.")
            openURL("x-apple.systempreferences:com.apple.preference.universalaccess"
                + "?SpeakSelectedText")
        case .pronunciation:
            // Marduk reads the system dictionary on every read, so the pane
            // IS Marduk's pronunciation editor — deep-link straight to it.
            speech.announce("Opening Read and Speak Content in System Settings. "
                + "Add pronunciations there — Marduk uses every entry, "
                + "including per-app ones, on its next read.")
            openURL("x-apple.systempreferences:com.apple.preference.universalaccess"
                + "?SpeakSelectedText")
        case .quit:
            // Clean exit 0 — under launchd (SuccessfulExit=false) this stays
            // stopped until next login or `marduk start`.
            announceThenExit("Marduk stopping.") { [self] in running = false }
        case .restart:
            announceThenExit("Restarting.") { [self] in
                if LaunchAgent.isInstalled {
                    pendingExitCode = 75  // launchd relaunches us
                } else {
                    let binary = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
                        .standardized
                    let daemon = Process()
                    daemon.executableURL = binary
                    daemon.arguments = ["start"]
                    try? daemon.run()
                }
                running = false
            }
        case .update:
            speech.announce("Update initiated")
            performUpdate()
        case .uninstall:
            guard LaunchAgent.isInstalled else {
                Earcon.error()
                speech.announce("The launch agent is not installed.")
                return
            }
            speech.announce("Removing the launch agent. Marduk will stop "
                + "and no longer start at login.") { [self] in
                DispatchQueue.main.async { [self] in
                    try? FileManager.default.removeItem(atPath: LaunchAgent.plistPath)
                    // Fire-and-forget: bootout SIGTERMs us — waiting on it
                    // here would deadlock (launchd waits for OUR exit).
                    let bootout = Process()
                    bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                    bootout.arguments = ["bootout", LaunchAgent.serviceTarget]
                    try? bootout.run()
                    // Safety net if the bootout never lands
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                        running = false
                    }
                }
            }
        case .log:
            if FileManager.default.fileExists(atPath: LaunchAgent.logPath) {
                speech.announce("Opening the log.")
                let opener = Process()
                opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                opener.arguments = [LaunchAgent.logPath]
                try? opener.run()
            } else {
                Earcon.error()
                speech.announce("No log file yet. The log exists when running "
                    + "under the launch agent.")
            }
        case .logCopy:
            guard let content = try? String(contentsOfFile: LaunchAgent.logPath,
                                            encoding: .utf8) else {
                Earcon.error()
                speech.announce("No log file to copy.")
                return
            }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            let tail = lines.suffix(100).joined(separator: "\n")
            _ = NSPasteboard.general.clearContents()
            _ = NSPasteboard.general.setString(tail, forType: .string)
            speech.announce("Copied the last \(min(lines.count, 100)) log lines. "
                + "The log never contains text Marduk has read, only key codes "
                + "and metadata — safe to paste into an issue.")
        case .feedback:
            speech.announce("Opening GitHub issues. Log lines are safe to "
                + "paste — the log never contains text Marduk has read.")
            openURL("https://github.com/spencer-dollahite/marduk/issues/new/choose")
        case .bug:
            speech.announce("Opening a bug report. Log lines are safe to "
                + "paste — the log never contains text Marduk has read.")
            // Issue forms accept per-field prefill by field id — spare the
            // reporter the eyes-free hunt for version and install channel
            let channel: String
            switch installChannel {
            case .source: channel = "source build"
            case .homebrew: channel = "Homebrew"
            case .release: channel = "release DMG"
            }
            let setup = "Marduk \(Marduk.version) (\(channel)), "
                + "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&=+")
            let encoded = setup.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            openURL("https://github.com/spencer-dollahite/marduk/issues/new"
                + "?template=bug_report.yml&setup=\(encoded)")
        case .security:
            // Security reports go to email, never public issues — say the
            // address aloud too, in case no mail client is configured
            speech.announce("Opening an email to report a security issue "
                + "privately. The address is spencer at s s dollahite dot com. "
                + "Please don't put security problems in public GitHub issues.")
            openURL("mailto:spencer@ssdollahite.com?subject=Marduk%20security%20report")
        case .config(let key, let value):
            applyConfig(key: key, value: value)
        case .unknown(let name):
            Earcon.error()
            let matches = ColonCommand.commandNames.filter { $0.hasPrefix(name) }
            if name.hasPrefix("config") || name.hasPrefix("set") {
                speech.announce("Config needs a setting and a value, like config rate 200.")
            } else if name.isEmpty {
                speech.announce("No command.")
            } else if matches.count > 1 {
                speech.announce("\(name) is ambiguous: \(matches.joined(separator: ", ")).")
            } else {
                speech.announce("Unknown command \(name). Type colon help.")
            }
        }
    }

    // MARK: - Update Checks

    private enum UpdateCheckOrigin { case manual, periodic, express }

    /// Single `u`: install if a check is armed, else check + speak notes.
    private func handleUpdateKey() {
        guard !releaseInFlight else {
            speech.announce("A release is running.")
            return
        }
        if let until = updateArmedUntil, Date() < until {
            updateArmedUntil = nil
            speech.announce("Update initiated")
            performUpdate()
            return
        }
        checkForUpdates(origin: .manual)
    }

    /// Fast `uu`: JUST INSTALL (user-final semantics — twice insisted).
    /// Never reads the notes and NEVER SPEAKS A COUNT (third ruling
    /// 2026-07-22): the flow is "Update initiated" now, "Update
    /// complete. Restarting." at the end — what happened, never how
    /// much. Already-known updates install immediately; otherwise a
    /// quiet check runs and installs whatever it finds. An up-to-date
    /// system says so and does nothing — the only typo protection that
    /// survives, by user choice.
    private func handleFastUpdateKey() {
        guard !releaseInFlight else {
            speech.announce("A release is running.")
            return
        }
        speech.announce("Update initiated")
        let armed = updateArmedUntil.map { Date() < $0 } ?? false
        if armed || updatesKnownAvailable {
            updateArmedUntil = nil
            performUpdate()
        } else {
            checkForUpdates(origin: .express)
        }
    }

    // MARK: - Cut release (dd)

    // A release publishes to strangers' machines (auto-update installs
    // it), so the gesture is the most consequential in Marduk: dd only
    // ASKS — the armed y/n question does the releasing. Patch bumps
    // only; minor/major are a human judgment and stay with the manual
    // scripts/release.sh. The daemon SPAWNS release.sh (its guards are
    // battle-tested: clean tree, ff-only, monotonic version, CI-green
    // gate) and narrates the script's own "==>" stage lines.
    private var releaseInFlight = false
    private var releaseProcess: Process?
    private var releaseWatchdog: DispatchWorkItem?
    private var releaseLastStage = "starting"
    private var releaseTimedOut = false

    private func handleReleaseKey() {
        guard let dir = projectDir else {
            // Defense in depth — the keyboard gesture is already
            // source-gated, but the socket/tests could reach here
            Earcon.error()
            speech.announce("Releases can only be cut from a source install.")
            return
        }
        guard !releaseInFlight else {
            // dd mid-release = the status poke: quiet by default, answers
            // with the current stage when asked
            speech.announce("Release in progress. \(releaseLastStage).")
            return
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            let tags = Self.shell("git", "tag", "--list", "v*",
                                  "--sort=v:refname", cwd: dir)
            let newest = tags.output.split(separator: "\n").last
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard tags.status == 0, let newest,
                  let next = ReleaseCheck.nextPatch(after: newest) else {
                fputs("[release] no usable version tag (status \(tags.status))\n", stderr)
                DispatchQueue.main.async { [self] in
                    Earcon.error()
                    speech.announce("Could not work out the next version from the git tags.")
                }
                return
            }
            DispatchQueue.main.async { [self] in
                guard !releaseInFlight else { return }
                // The dialog-focus pattern: speak the question, extend the
                // answer window when the speech finishes, one-key answer.
                // Escape, any other key, or ~20s quietly cancels.
                speech.announce("Cut release \(next)? Press y to release, "
                    + "n to cancel.") { [weak keyboardMonitor] in
                    keyboardMonitor?.extendQuestionWindow()
                }
                keyboardMonitor?.armQuestion(keys: ["y", "n"]) { [self] answer in
                    if answer == "y" {
                        startRelease(version: next, dir: dir)
                    } else {
                        speech.announce("Not releasing.")
                    }
                }
            }
        }
    }

    /// Spawn scripts/release.sh and narrate its "==>" stages. Main-thread
    /// entry; the process runs detached with a pipe reader. No blanket
    /// fail-open: CI-wait and notarization are network-idle and the
    /// keyboard must stay alive — the latency sentinel already fail-opens
    /// dynamically if the release build starves the main thread.
    private func startRelease(version: String, dir: String) {
        releaseInFlight = true
        releaseTimedOut = false
        releaseLastStage = "starting"
        fputs("[release] cutting \(version) via scripts/release.sh\n", stderr)
        speech.announce("Cutting release \(version).")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["scripts/release.sh", version]
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        // The launchd daemon's PATH lacks Homebrew, and release.sh needs
        // gh (git/swift/xcrun live in /usr/bin)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:"
            + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Stages are TRACKED, not spoken (user-tuned: the run is usable
        // time — reads and motions keep working — and a stage announce()
        // would stop an active read every few minutes). The log carries
        // the full narration; dd while running speaks the current stage
        // on demand; only start, success, and failure interrupt.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else {
                return
            }
            for line in chunk.split(separator: "\n") {
                let text = String(line)
                fputs("[release] \(text)\n", stderr)
                if let stage = ReleaseCheck.stageLine(text) {
                    DispatchQueue.main.async { [weak self] in
                        self?.releaseLastStage = stage
                    }
                }
            }
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                self.releaseWatchdog?.cancel()
                self.releaseWatchdog = nil
                self.releaseProcess = nil
                self.releaseInFlight = false
                if proc.terminationStatus == 0 {
                    fputs("[release] \(version) is live\n", stderr)
                    self.speech.announce("Release \(version) is live.")
                } else if self.releaseTimedOut {
                    Earcon.error()
                    self.speech.announce("Release timed out during "
                        + "\(self.releaseLastStage). Check the log.")
                } else {
                    fputs("[release] failed (status \(proc.terminationStatus)) "
                        + "during \(self.releaseLastStage)\n", stderr)
                    Earcon.error()
                    self.speech.announce("Release failed during "
                        + "\(self.releaseLastStage). Check the log.")
                }
            }
        }

        // Watchdog: a locked keychain (codesign GUI prompt) or a hung
        // notarization must not wedge silently — the osascript
        // kill-on-timeout precedent, scaled to release length.
        let watchdog = DispatchWorkItem { [weak self, weak process] in
            guard let self, self.releaseInFlight else { return }
            fputs("[release] watchdog: 45 minutes — terminating\n", stderr)
            self.releaseTimedOut = true
            process?.terminate()
        }
        releaseWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 45 * 60, execute: watchdog)

        do {
            try process.run()
            releaseProcess = process
        } catch {
            releaseInFlight = false
            releaseWatchdog?.cancel()
            releaseWatchdog = nil
            fputs("[release] failed to launch release.sh: \(error)\n", stderr)
            Earcon.error()
            speech.announce("Could not start the release script.")
        }
    }

    /// How this copy got onto the machine — decides both the update
    /// mechanism (git pull vs pointing at a channel) and the wording.
    private enum InstallChannel { case source, homebrew, release }

    private var installChannel: InstallChannel {
        if projectDir != nil { return .source }
        let fm = FileManager.default
        if fm.fileExists(atPath: "/opt/homebrew/Caskroom/marduk")
            || fm.fileExists(atPath: "/usr/local/Caskroom/marduk") {
            return .homebrew
        }
        return .release
    }

    /// "…is available." + how to actually get it, per channel.
    private var releaseUpdateHint: String {
        installChannel == .homebrew
            ? "Run brew upgrade to install it."
            : "Download it from the GitHub releases page."
    }

    /// Fetches origin/main off the main thread and reports what's new.
    private func checkForUpdates(origin: UpdateCheckOrigin) {
        guard !releaseInFlight else {
            // release.sh owns the repo right now — a concurrent pull or
            // build would collide with it. Periodic ticks retry next cycle.
            if origin != .periodic { speech.announce("A release is running.") }
            return
        }
        guard let dir = projectDir else {
            // No repo above the binary = installed from a release or via
            // Homebrew — git-based updates don't apply, but the latest
            // release tag tells us whether something newer exists.
            checkLatestRelease(origin: origin)
            return
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            let fetch = Self.shell("git", "fetch", "--quiet", "origin", "main", cwd: dir)
            guard fetch.status == 0 else {
                fputs("[update] fetch failed: \(fetch.output)\n", stderr)
                if origin == .manual {
                    DispatchQueue.main.async { [self] in
                        Earcon.error()
                        speech.announce("Update check failed. Is the network up?")
                    }
                }
                return
            }
            let subjects = Self.shell("git", "log", "--format=%s", "HEAD..origin/main", cwd: dir)
                .output.split(separator: "\n").map(String.init)
            let remote = Self.shell("git", "rev-parse", "origin/main", cwd: dir)
                .output.trimmingCharacters(in: .whitespacesAndNewlines)
            let checks = subjects.isEmpty ? CheckStatus.none
                                          : Self.remoteCheckStatus(sha: remote)
            DispatchQueue.main.async { [self] in
                handleCheckResult(subjects: subjects, remote: remote,
                                  checks: checks, origin: origin)
            }
        }
    }

    /// Release/Homebrew installs: compare the running version against the
    /// latest GitHub release. The channel now SELF-UPDATES (download +
    /// verify + swap, see performReleaseUpdate), so this mirrors the
    /// source channel end to end: manual = speak the release notes and
    /// arm the press-u-again window; periodic + auto = silent install
    /// (deferred while speech is active); periodic without auto =
    /// announce each new version exactly once. API/network failure falls
    /// back to a generic pointer on manual and stays silent on periodic —
    /// never a false "up to date".
    private func checkLatestRelease(origin: UpdateCheckOrigin) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let result = Self.shell("curl", "-s", "-m", "10",
                                    "-H", "User-Agent: marduk",
                                    "-H", "Accept: application/vnd.github+json",
                                    "https://api.github.com/repos/spencer-dollahite/marduk/releases/latest",
                                    cwd: "/tmp")
            let release = result.status == 0
                ? ReleaseCheck.parseLatestRelease(result.output) : nil
            DispatchQueue.main.async { [self] in
                guard let release else {
                    if origin != .periodic {
                        speech.announce("This copy of Marduk was installed from a "
                            + "release. " + releaseUpdateHint)
                    }
                    return
                }
                // Strictly newer, never merely different: every signature
                // check passes for an older signed build too, so an
                // equal-or-older "latest" is treated as up to date rather
                // than walked backwards onto a known-bad version.
                if !ReleaseCheck.isNewer(release.tag, than: Marduk.version) {
                    updatesKnownAvailable = false
                    if origin != .periodic { speech.announce("Marduk is up to date.") }
                } else if origin == .express {
                    updatesKnownAvailable = true
                    // No pre-announcement (user ruling): "Update initiated"
                    // already spoke; "Marduk vX installed. Restarting."
                    // closes the loop with the version, not a count
                    performReleaseUpdate(silent: false)
                } else if origin == .manual {
                    updatesKnownAvailable = true
                    updateArmedUntil = Date(timeIntervalSinceNow: 60)
                    let notes = release.notes.isEmpty ? ""
                        : " " + release.notes.prefix(8).joined(separator: ". ") + "."
                    speech.announce("Marduk \(release.tag) is available.\(notes) "
                        + "Press u again to install.")
                } else if autoUpdate {
                    updatesKnownAvailable = true
                    if speech.isSpeaking {
                        // Same courtesy as the source channel: never
                        // restart mid-read; try again later
                        fputs("[update] speech active — deferring auto-update\n", stderr)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [self] in
                            checkLatestRelease(origin: .periodic)
                        }
                    } else {
                        fputs("[update] auto-installing release \(release.tag)\n", stderr)
                        DispatchQueue.global(qos: .userInitiated).async { [self] in
                            performReleaseUpdate(silent: true)
                        }
                    }
                } else if lastAnnouncedRelease != release.tag {
                    lastAnnouncedRelease = release.tag
                    speech.announce("Marduk \(release.tag) is available. "
                        + "Press u to hear what's new.")
                }
            }
        }
    }

    /// CI verdict for a commit, via GitHub's public check-runs API.
    /// `.none` (no runs, or any API/network failure) must NEVER block an
    /// update — pre-CI commits and offline checks still work.
    private enum CheckStatus { case passed, failed, pending, none }

    private static func remoteCheckStatus(sha: String) -> CheckStatus {
        guard !sha.isEmpty else { return .none }
        let result = shell("curl", "-s", "-m", "10",
                           "-H", "User-Agent: marduk",
                           "-H", "Accept: application/vnd.github+json",
                           "https://api.github.com/repos/spencer-dollahite/marduk/commits/\(sha)/check-runs",
                           cwd: "/tmp")
        guard result.status == 0,
              let json = try? JSONSerialization.jsonObject(
                  with: Data(result.output.utf8)) as? [String: Any],
              let runs = json["check_runs"] as? [[String: Any]],
              !runs.isEmpty else { return .none }

        var pending = false
        for run in runs {
            if run["status"] as? String != "completed" {
                pending = true
                continue
            }
            if let conclusion = run["conclusion"] as? String,
               ["failure", "timed_out", "cancelled"].contains(conclusion) {
                return .failed
            }
        }
        return pending ? .pending : .passed
    }

    private func handleCheckResult(subjects: [String], remote: String,
                                   checks: CheckStatus, origin: UpdateCheckOrigin) {
        guard !subjects.isEmpty else {
            updatesKnownAvailable = false
            if origin != .periodic { speech.announce("Marduk is up to date.") }
            return
        }
        updatesKnownAvailable = true
        fputs("[update] \(subjects.count) update(s) available, checks: \(checks)\n", stderr)
        switch origin {
        case .express:
            // No count (user ruling): "Update initiated" already spoke;
            // "Update complete. Restarting." closes the loop
            performUpdate()
        case .manual:
            // Release notes = commit subjects since the running build.
            // Arm BEFORE speaking so a quick second u installs immediately.
            updateArmedUntil = Date(timeIntervalSinceNow: 60)
            let listed = subjects.prefix(8)
            var text = subjects.count == 1
                ? "One update available. "
                : "\(subjects.count) updates available. "
            text += listed.joined(separator: ". ")
            if subjects.count > listed.count {
                text += ". And \(subjects.count - listed.count) more"
            }
            // CI verdict is informative here — the user decides; the local
            // zero-warning build gate remains the hard floor either way.
            switch checks {
            case .passed:  text += ". Checks passing"
            case .failed:  text += ". Warning: the latest update is failing its checks"
            case .pending: text += ". Checks are still running"
            case .none:    break
            }
            text += ". Press u again to install."
            speech.speak(text)
        case .periodic:
            // The silent auto-path is strict: only green (or check-less)
            // commits install themselves. Next timer tick re-evaluates.
            if checks == .failed || checks == .pending {
                fputs("[update] checks \(checks) on remote — holding back auto-update\n", stderr)
                return
            }
            if autoUpdate {
                // Never interrupt: no announcements, and never restart while
                // something is being spoken — retry in 10 minutes instead.
                if speech.isSpeaking {
                    guard !autoRetryScheduled else { return }
                    autoRetryScheduled = true
                    fputs("[update] speech active — deferring auto-update\n", stderr)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [self] in
                        autoRetryScheduled = false
                        checkForUpdates(origin: .periodic)
                    }
                } else {
                    fputs("[update] auto-installing silently\n", stderr)
                    performUpdate(silent: true)
                }
            } else if lastAnnouncedRemote != remote {
                // Announce each new remote head exactly once — no nagging
                lastAnnouncedRemote = remote
                speech.announce("Marduk update available. Press u to hear what's new.")
            }
        }
    }

    /// (Re)schedules the periodic check; first check ~2 minutes after start
    /// so a fresh boot stays quiet. checkHours 0 disables entirely.
    private func scheduleUpdateChecks() {
        updateCheckTimer?.cancel()
        updateCheckTimer = nil
        guard updateCheckHours > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(120),
                       repeating: .seconds(updateCheckHours * 3600))
        timer.setEventHandler { [weak self] in
            self?.checkForUpdates(origin: .periodic)
        }
        timer.resume()
        updateCheckTimer = timer
    }

    private func openURL(_ url: String) {
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = [url]
        try? opener.run()
    }

    /// "?" or a typing pause in COMMAND mode: speak what can come next.
    /// The idle path stays silent when there's nothing to offer.
    private func speakCommandOptions(explicit: Bool) {
        var displays = commandCandidates.map(\.display)
        if displays.isEmpty {
            if explicit { speech.announce("No options here. Press Return to run it.") }
            return
        }
        // Pickers list dozens of rows (voices, every installed app) — don't
        // recite them all; arrows walk them one at a time anyway
        if ColonCommand.pickerCommands.contains(where: {
            commandBufferSnapshot.hasPrefix($0)
        }), displays.count > 8 {
            let more = displays.count - 6
            displays = Array(displays.prefix(6)) + ["and \(more) more"]
        }
        speech.speak("Options: " + displays.joined(separator: ", ") + ".")
    }

    /// Publish daemon liveness to Karabiner (fire-and-forget): rules can
    /// route a button to Marduk's read chord (Ctrl+Option+Escape — the
    /// Option+Escape handler already accepts extra modifiers) while up,
    /// and to plain Option+Escape (macOS Speak Selection) while down —
    /// automatic system fallback on the same button. Set on start and
    /// enable, cleared on clean stop and disable. A hard crash can't
    /// clear it — the fallback gap lasts until KeepAlive relaunches
    /// (seconds). No Karabiner installed → silently skipped.
    private static func setKarabinerVariable(up: Bool) {
        let cli = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
        guard FileManager.default.isExecutableFile(atPath: cli) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["--set-variables", "{\"marduk_up\":\(up ? 1 : 0)}"]
        try? process.run() // fire and forget — never block on Karabiner
        fputs("[keyboard] karabiner marduk_up=\(up ? 1 : 0)\n", stderr)
    }

    // MARK: - Karabiner profile ("Marduk brings its own config")

    /// Arm the crash-restore path: pre-build the karabiner_cli argv
    /// vectors so the signal handler touches only prepared memory
    /// (posix_spawn and raise are async-signal-safe; allocation is not).
    /// Covers SIGSEGV/SIGABRT/etc — the user's profile comes back even
    /// when Marduk dies mid-flight. SIGKILL/power loss can't be caught;
    /// KeepAlive's relaunch re-activates and self-heals that gap.
    private static func armCrashRestore(userProfile: String) {
        let cli = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
        guard FileManager.default.isExecutableFile(atPath: cli) else { return }
        gKarabinerCLIPath = strdup(cli)
        gCrashProfileArgv = makeArgv([cli, "--select-profile", userProfile])
        gCrashVariableArgv = makeArgv([cli, "--set-variables", "{\"marduk_up\":0}"])
        for sig in [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig, mardukCrashRestore)
        }
    }

    private static func makeArgv(_ args: [String])
        -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
            .allocate(capacity: args.count + 1)
        for (i, arg) in args.enumerated() { argv[i] = strdup(arg) }
        argv[args.count] = nil
        return argv
    }

    /// The user's own profile name, remembered at activation so clean
    /// stop / Ctrl+Option+M disable can hand the keyboard back to it.
    private var karabinerUserProfile: String?

    private static let karabinerConfigPath =
        NSHomeDirectory() + "/.config/karabiner/karabiner.json"

    /// Marduk maintains its OWN Karabiner profile, fully automatically —
    /// the user never switches anything by hand. Contract: the profile
    /// NAMED "Marduk" belongs to Marduk. If the user already made one
    /// (their case), it's ADOPTED — everything they put in it is
    /// preserved; only Marduk's own rule (matched by description) is
    /// refreshed inside it on every activation. If none exists, it's
    /// bootstrapped as a clone of the selected profile so the user's rig
    /// carries over. Selection goes through karabiner_cli (the supported
    /// path; file-watch reload is flaky). Safety: karabiner.json is
    /// backed up beside itself before every rewrite, a parse failure
    /// means nothing is written, and non-Marduk profiles are never
    /// modified or deleted. The read button's key_code comes from
    /// keyboard.karabinerReadKey (default equal_sign — a Razer Naga's
    /// side button 12).
    /// PURE karabiner.json surgery, unit-tested with fixtures (the actual
    /// KE driver can never run on CI — a DriverKit extension needs an
    /// interactive approval — so the high-stakes half, rewriting the
    /// user's config, is what the tests pin down). Nil = leave the file
    /// alone (no profiles / no usable source).
    static func rewriteKarabinerConfig(_ input: [String: Any], key: String,
                                       vendorId: Int, productId: Int?)
        -> (root: [String: Any], userProfile: String?)? {
        var root = input
        guard var profiles = root["profiles"] as? [[String: Any]],
              !profiles.isEmpty else { return nil }

        // The user's own profile: selected and not ours (after a crash the
        // selected one may still be "Marduk" — fall back to any other)
        let userProfile = (profiles.first(where: {
            ($0["selected"] as? Bool == true) && ($0["name"] as? String) != "Marduk"
        }) ?? profiles.first(where: { ($0["name"] as? String) != "Marduk" }))?["name"] as? String

        var marduk: [String: Any]
        if let existing = profiles.first(where: { ($0["name"] as? String) == "Marduk" }) {
            marduk = existing  // adopt as-is; only our rule is refreshed
        } else {
            guard let source = profiles.first(where: {
                ($0["name"] as? String) == userProfile
            }) else { return nil }
            marduk = source
            marduk["name"] = "Marduk"
            marduk["selected"] = false  // karabiner_cli does the selecting
            fputs("[marduk] no Marduk profile — bootstrapping from "
                + "\"\(userProfile ?? "?")\"\n", stderr)
        }
        var cm = marduk["complex_modifications"] as? [String: Any] ?? [:]
        var rules = cm["rules"] as? [[String: Any]] ?? []
        rules.removeAll {
            let d = ($0["description"] as? String) ?? ""
            return d.hasPrefix("Marduk read button") || d.hasPrefix("Marduk panic chord")
        }
        rules.insert(panicRule(), at: 0)
        rules.insert(readButtonRule(key: key, vendorId: vendorId,
                                    productId: productId), at: 0)
        cm["rules"] = rules
        marduk["complex_modifications"] = cm

        if let index = profiles.firstIndex(where: { ($0["name"] as? String) == "Marduk" }) {
            profiles[index] = marduk
        } else {
            profiles.append(marduk)
        }
        root["profiles"] = profiles
        return (root, userProfile)
    }

    private func activateKarabinerProfile() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.karabinerConfigPath) else { return }
        guard let data = fm.contents(atPath: Self.karabinerConfigPath),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            fputs("[marduk] karabiner.json unreadable — leaving it alone\n", stderr)
            return
        }
        guard let (root, userProfile) = Self.rewriteKarabinerConfig(
                  parsed,
                  key: config.keyboard?.karabinerReadKey ?? "equal_sign",
                  vendorId: config.keyboard?.karabinerReadVendorId ?? 5426,
                  productId: config.keyboard?.karabinerReadProductId) else { return }
        karabinerUserProfile = userProfile

        do {
            let backup = Self.karabinerConfigPath + ".marduk-backup"
            try? fm.removeItem(atPath: backup)
            try fm.copyItem(atPath: Self.karabinerConfigPath, toPath: backup)
            let out = try JSONSerialization.data(withJSONObject: root,
                                                 options: [.prettyPrinted, .sortedKeys])
            try out.write(to: URL(fileURLWithPath: Self.karabinerConfigPath), options: .atomic)
        } catch {
            fputs("[marduk] karabiner.json write failed: \(error.localizedDescription)\n", stderr)
            return
        }
        fputs("[marduk] Karabiner profile ready (user profile: "
            + "\"\(karabinerUserProfile ?? "?")\")\n", stderr)
        Self.karabinerCLI("--select-profile", "Marduk")
        if let name = karabinerUserProfile {
            Self.armCrashRestore(userProfile: name)
        }
    }

    /// Marduk assumes Karabiner but never requires it — runtime absence
    /// is silent by design. ONBOARDING absence shouldn't be: an audio-
    /// first user can't discover that button-mapped reads, the automatic
    /// macOS fallback, and non-US-layout support exist behind an install
    /// they've never heard of. Spoken once per install (marker written
    /// when actually spoken), delayed and yielding so it can never talk
    /// over the first-run welcome or an early read.
    /// Running on a macOS major newer than Marduk has been validated on:
    /// say so once per major — early upgraders should expect oddities and
    /// know the update train will carry fixes. Same yielding-delay shape
    /// as the Karabiner hint so it never talks over the welcome.
    private func announceUntestedMacOSOnce() {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        guard major > Marduk.testedMacOSMajor else { return }
        onboarding.notice("macos-\(major)-noticed", delay: 35, retries: 3,
            "A note: you are running macOS \(major), newer than this version "
            + "of Marduk has been tested on. Most things should work. If "
            + "something misbehaves, press u — a compatibility update may "
            + "already be waiting.")
    }

    private func announceKarabinerAbsenceOnce() {
        let cli = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
        guard !FileManager.default.isExecutableFile(atPath: cli) else { return }
        onboarding.notice("ke-noticed", delay: 25, retries: 2,
            "A tip: Marduk is designed to pair with Karabiner Elements. "
            + "Everything works without it, but installing Karabiner unlocks "
            + "mapping a mouse button to reads, automatic fallback to the "
            + "system voice whenever Marduk is off, and remapped keyboard "
            + "layouts. Details are in the read me.")
    }

    /// Hand the keyboard back to the user's own profile. Every exit path
    /// lands here or in a sibling: clean stop and Ctrl+Option+M call this
    /// directly, SIGTERM drains into the clean teardown, and hard crashes
    /// run the armed signal handler (mardukCrashRestore). Only SIGKILL /
    /// power loss escape all three — KeepAlive's relaunch re-activates
    /// and heals that within seconds.
    private func deactivateKarabinerProfile() {
        guard let name = karabinerUserProfile else { return }
        Self.karabinerCLI("--select-profile", name)
    }

    /// The rule injected into the Marduk profile: read button → Marduk's
    /// chord while marduk_up is 1, macOS Speak Selection otherwise (first
    /// matching manipulator wins). The variable condition matters even
    /// inside our own profile: after a crash the profile is still
    /// selected but the daemon is gone — the fallback keeps the button
    /// alive. Mirrors assets/karabiner/marduk-read-button.json.
    /// The rule is DEVICE-SCOPED: equal_sign is also the real keyboard's
    /// =/+ key, and an unscoped rule ate it in every mode (field report —
    /// typing plus/equals was impossible). Default scope is vendor 5426
    /// (Razer, the Naga assumption behind the default key);
    /// keyboard.karabinerReadVendorId/ProductId override, vendorId 0 =
    /// any device (the old behavior, for exotic setups). BOTH manipulators
    /// carry the condition — the fallback would otherwise turn the
    /// keyboard's = into Option+Escape whenever Marduk is down.
    /// PANIC CHORD, handled entirely by Karabiner — upstream of Marduk's
    /// event tap, so it works precisely when a wedged Marduk is strangling
    /// the keyboard (field: main-thread starvation left keys half-dead and
    /// the user rebooting). Kills hard; KeepAlive relaunches fresh in ~10s
    /// and repeated panics walk BootGuard into safe mode. Ctrl+Option+
    /// Delete: memorable, two-handed enough to never happen by accident.
    static func panicRule() -> [String: Any] {
        [
            "description": "Marduk panic chord (managed by Marduk — regenerated every start)",
            "manipulators": [[
                "type": "basic",
                "from": ["key_code": "delete_or_backspace",
                         "modifiers": ["mandatory": ["control", "option"]]],
                "to": [["shell_command": "/usr/bin/pkill -9 marduk"]],
            ]],
        ]
    }

    static func readButtonRule(key: String, vendorId: Int,
                                       productId: Int?) -> [String: Any] {
        var deviceCondition: [String: Any]?
        if vendorId != 0 {
            var identifiers: [String: Any] = ["vendor_id": vendorId]
            if let productId { identifiers["product_id"] = productId }
            deviceCondition = ["type": "device_if", "identifiers": [identifiers]]
        }
        func manipulator(_ conditions: [[String: Any]], toModifiers: [String]) -> [String: Any] {
            var all = conditions
            if let deviceCondition { all.append(deviceCondition) }
            var m: [String: Any] = [
                "type": "basic",
                "from": ["key_code": key, "modifiers": ["optional": ["any"]]],
                "to": [["key_code": "escape", "modifiers": toModifiers]],
            ]
            if !all.isEmpty { m["conditions"] = all }
            return m
        }
        return [
            "description": "Marduk read button (managed by Marduk — regenerated every start)",
            "manipulators": [
                manipulator([["type": "variable_if", "name": "marduk_up", "value": 1]],
                            toModifiers: ["left_control", "left_option"]),
                manipulator([], toModifiers: ["left_option"]),
            ],
        ]
    }

    private static func karabinerCLI(_ args: String...) {
        let cli = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
        guard FileManager.default.isExecutableFile(atPath: cli) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = args
        try? process.run() // fire and forget
        fputs("[marduk] karabiner_cli \(args.joined(separator: " "))\n", stderr)
    }

    /// Entering the ":voices" picker. When no premium English voice is
    /// installed, teach the one-time download path — there is no API to
    /// fetch Apple's premium voices on the user's behalf. (Pane name per
    /// current macOS: "Read and Speak Content".)
    private func announceVoicesPicker() {
        let hasPremium = AVSpeechSynthesisVoice.speechVoices().contains {
            $0.language.hasPrefix("en") && $0.quality == .premium
        }
        speech.announce(hasPremium ? "voices"
            : "voices. For more natural voices, download a premium voice like "
            + "Ava: System Settings, Accessibility, Read and Speak Content, "
            + "System Voice, Manage Voices. Free, entirely on device — it "
            + "will appear here to audition.")
    }

    /// Applies and persists the reading voice — the ":voices" picker accept.
    private func applyVoice(identifier: String) {
        guard let voice = AVSpeechSynthesisVoice(identifier: identifier) else {
            Earcon.error()
            speech.announce("That voice is not installed.")
            return
        }
        speech.voice = voice
        config.speech.voiceIdentifier = identifier
        ConfigLoader.save(config)
        fputs("[speech] Reading voice set to \(voice.name) (\(identifier))\n", stderr)
        // READ voice on purpose: the confirmation demos the choice
        speech.speak("This is \(voice.name).")
    }

    // MARK: - Staged pickers

    /// Route an accepted picker row to whatever that picker does. One
    /// switch, so a new picker is a case here plus its row source — not a
    /// new set of prefix checks threaded through the tap and the palette.
    private func applyPickerRow(_ picker: String, identifier: String) {
        switch picker {
        case "voices": applyVoice(identifier: identifier)
        case "invertapps": toggleInvertApp(identifier: identifier)
        default: break
        }
    }

    private func announcePickerEntry(_ picker: String) {
        switch picker {
        case "voices":
            announceVoicesPicker()
        case "invertapps":
            speech.announce("invert apps. Choose an app to invert the display "
                + "while it is in front. Return adds it, or removes it if it "
                + "is already on the list.")
        default: break
        }
    }

    /// The ":invertapps" rows: the app the user was just in FIRST (the
    /// whole point — you notice an app is blinding while you're in it),
    /// then everything running, then everything installed. Bundle IDs stay
    /// out of the display entirely; nobody should need to know theirs.
    private func invertAppOptions() -> [(name: String, identifier: String)] {
        let listed = Set(config.display.invertForApps)
        var seen = Set<String>()
        if let own = Bundle.main.bundleIdentifier { seen.insert(own) }
        var rows: [(name: String, identifier: String)] = []

        func add(_ name: String, _ id: String) {
            guard !seen.contains(id) else { return }
            seen.insert(id)
            // Spoken, so the state has to be a word, not a checkmark
            let builtIn = DisplayInverter.builtInInvertPrefixes
                .contains { id.hasPrefix($0) }
            let suffix = builtIn ? " — always inverts (built in)"
                : (listed.contains(id) ? " — inverting" : "")
            rows.append((name + suffix, id))
        }

        if let front = keyboardMonitor?.lastForeignApp { add(front.name, front.id) }
        for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular {
            if let id = app.bundleIdentifier { add(app.localizedName ?? id, id) }
        }
        // Anything already on the list but neither running nor installed
        // must still be removable
        for id in config.display.invertForApps.sorted() { add(id, id) }
        for app in Self.installedApps() { add(app.name, app.identifier) }
        return rows
    }

    /// Every .app in the standard locations, name + bundle ID from its own
    /// Info.plist. Best-effort: an unreadable bundle is simply skipped.
    private static func installedApps() -> [(name: String, identifier: String)] {
        let fm = FileManager.default
        let roots = [URL(fileURLWithPath: "/Applications"),
                     URL(fileURLWithPath: "/Applications/Utilities"),
                     fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
                     URL(fileURLWithPath: "/System/Applications"),
                     URL(fileURLWithPath: "/System/Applications/Utilities")]
        var found: [(name: String, identifier: String)] = []
        for root in roots {
            let entries = (try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)) ?? []
            for url in entries where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url),
                      let id = bundle.bundleIdentifier else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName")
                    as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                found.append((name, id))
            }
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Add or remove an app from `display.invertForApps` — the picker's
    /// accept. Toggling means one command both adds and removes, so there
    /// is no second gesture to learn.
    private func toggleInvertApp(identifier: String) {
        let name = invertAppOptions().first { $0.identifier == identifier }?.name
            .components(separatedBy: " — ").first ?? identifier
        if DisplayInverter.builtInInvertPrefixes.contains(where: { identifier.hasPrefix($0) }) {
            speech.announce("\(name) already inverts the display. It is built in, "
                + "so there is nothing to add.")
            return
        }
        var list = config.display.invertForApps
        let removing = list.contains(identifier)
        if removing {
            list.removeAll { $0 == identifier }
        } else {
            list.append(identifier)
        }
        config.display.invertForApps = list
        ConfigLoader.save(config)
        displayInverter?.invertApps = Set(list)  // live, no restart
        fputs("[display] invert list: \(removing ? "removed" : "added") "
            + "\(identifier) (\(list.count) total)\n", stderr)
        let inversionOn = (config.display.invertEnabled ?? false)
            || (config.display.autoInvert ?? false)
        let caveat = inversionOn ? ""
            : " Inverting is switched off, so run colon config invert on to use it."
        speech.announce(removing
            ? "\(name) removed. It no longer inverts the display."
            : "\(name) added. The display will invert while it is in front.\(caveat)")
    }

    /// Applies a setting live AND persists it. Failures speak and change
    /// nothing. Number ranges come from the same table the palette shows.
    private func applyConfig(key: String, value: String) {
        func fail(_ message: String) {
            Earcon.error()
            speech.announce(message)
        }
        func toggle() -> Bool? {
            value == "on" ? true : (value == "off" ? false : nil)
        }
        func number() -> Int? {
            guard case .number(let min, let max, _)? = ColonCommand.kind(for: key),
                  let n = Int(value), n >= min, n <= max else { return nil }
            return n
        }

        switch key {
        case "rate":
            guard let wpm = number() else {
                return fail("Rate must be 50 to 360 words per minute.")
            }
            let rate = Float(wpm) / 360.0
            speech.rate = rate
            config.speech.rate = rate
            ConfigLoader.save(config)
            // The moment rate is on their mind — mention the live nudge,
            // claimed BEFORE speaking (while the synthesizer is quiet, so
            // the pacing gate sees the truth) and chained onto the
            // confirmation so it rides the action instead of arriving
            // later out of nowhere.
            let rateTip = (config.keyboard?.speedKeys ?? false) || tutorial.isActive
                ? nil : onboarding.claim(.rateChange)
            // READ voice on purpose: the confirmation demos the new rate
            speech.speak("Rate set to \(wpm) words per minute.") { [self] in
                guard let rateTip else { return }
                DispatchQueue.main.async { [self] in speech.announce(rateTip) }
            }

        case "pitch":
            guard let percent = number() else {
                return fail("Pitch must be 50 to 200 percent.")
            }
            speech.pitch = Float(percent) / 100.0
            config.speech.pitch = speech.pitch
            ConfigLoader.save(config)
            // READ voice on purpose: the confirmation demos the new pitch
            speech.speak("Pitch \(percent) percent.")

        case "level":
            guard ["none", "some", "most", "all"].contains(value) else {
                return fail("Level must be none, some, most, or all.")
            }
            var v = config.verbalizer ?? .init()
            v.level = value
            config.verbalizer = v
            speech.preprocessor = SpeechPreprocessor.settings(from: config.verbalizer)
            ConfigLoader.save(config)
            speech.announce("Verbalizer level \(value).")

        case "hashes":
            guard let on = toggle() else { return fail("Say on or off.") }
            var v = config.verbalizer ?? .init()
            v.hashes = on
            config.verbalizer = v
            speech.preprocessor = SpeechPreprocessor.settings(from: config.verbalizer)
            ConfigLoader.save(config)
            speech.announce("Hash abbreviation \(value).")

        case "identifiers":
            guard let on = toggle() else { return fail("Say on or off.") }
            var v = config.verbalizer ?? .init()
            v.identifiers = on
            config.verbalizer = v
            speech.preprocessor = SpeechPreprocessor.settings(from: config.verbalizer)
            ConfigLoader.save(config)
            speech.announce("Identifier splitting \(value).")

        case "rescue":
            guard let on = toggle() else { return fail("Say on or off.") }
            keyboardMonitor?.typingRescueEnabled = on
            var kb = config.keyboard ?? .init()
            kb.typingRescue = on
            config.keyboard = kb
            ConfigLoader.save(config)
            speech.announce("Typing rescue \(value).")

        case "burst":
            guard let ms = number() else {
                return fail("Burst must be 50 to 2000 milliseconds.")
            }
            keyboardMonitor?.typingBurstThreshold = TimeInterval(ms) / 1000.0
            var kb = config.keyboard ?? .init()
            kb.typingBurstMs = ms
            config.keyboard = kb
            ConfigLoader.save(config)
            speech.announce("Typing burst \(ms) milliseconds.")

        case "escapehold":
            guard let ms = number() else {
                return fail("Escape hold must be 100 to 2000 milliseconds.")
            }
            keyboardMonitor?.escapeHoldThreshold = TimeInterval(ms) / 1000.0
            var kb = config.keyboard ?? .init()
            kb.escapeHoldMs = ms
            config.keyboard = kb
            ConfigLoader.save(config)
            speech.announce("Escape hold \(ms) milliseconds.")

        case "echo":
            guard let on = toggle() else { return fail("Say on or off.") }
            keyboardMonitor?.typingEchoEnabled = on
            var kb = config.keyboard ?? .init()
            kb.typingEcho = on
            config.keyboard = kb
            ConfigLoader.save(config)
            speech.announce("Typing echo \(value).")

        case "commandecho":
            guard let on = toggle() else { return fail("Say on or off.") }
            keyboardMonitor?.commandEchoEnabled = on
            var kb = config.keyboard ?? .init()
            kb.commandEcho = on
            config.keyboard = kb
            ConfigLoader.save(config)
            speech.announce("Command echo \(value).")

        case "palette":
            guard let on = toggle() else { return fail("Say on or off.") }
            paletteEnabled = on
            if !on { palette.hide() }
            var kb = config.keyboard ?? .init()
            kb.commandPalette = on
            config.keyboard = kb
            ConfigLoader.save(config)
            speech.announce("Palette \(value).")

        case "position":
            guard let mode = CommandPalette.PositionMode(rawValue: value) else {
                return fail("Position must be center or pointer.")
            }
            palette.positionMode = mode
            var kb = config.keyboard ?? .init()
            kb.palettePosition = value
            config.keyboard = kb
            ConfigLoader.save(config)
            speech.announce("Palette position \(value).")

        case "border":
            guard let on = toggle() else { return fail("Say on or off.") }
            var ov = config.overlay ?? .init()
            ov.borderEnabled = on
            config.overlay = ov
            ConfigLoader.save(config)
            rebuildOverlay()
            speech.announce("Mode border \(value).")

        case "pointer":
            guard let on = toggle() else { return fail("Say on or off.") }
            var ov = config.overlay ?? .init()
            ov.pointerEnabled = on
            config.overlay = ov
            ConfigLoader.save(config)
            rebuildOverlay()
            speech.announce("Pointer dot \(value).")

        case "thickness":
            guard let points = number() else {
                return fail("Thickness must be 1 to 40 points.")
            }
            var ov = config.overlay ?? .init()
            ov.thickness = points
            config.overlay = ov
            ConfigLoader.save(config)
            rebuildOverlay()
            speech.announce("Border thickness \(points) points.")

        case "speedkeys":
            guard let on = toggle() else { return fail("Say on or off.") }
            keyboardMonitor?.speedKeysEnabled = on
            var kb = config.keyboard ?? .init()
            kb.speedKeys = on
            config.keyboard = kb
            ConfigLoader.save(config)
            speech.announce(on ? "Speed keys on. Option up and down change the rate."
                               : "Speed keys off.")

        case "dialogs":
            guard let level = DialogSentinel.Level(rawValue: value) else {
                return fail("Say all, system, or off.")
            }
            dialogSentinel.level = level
            var kb = config.keyboard ?? .init()
            kb.dialogLevel = value
            kb.dialogAlerts = level != .off  // keep the legacy key coherent
            config.keyboard = kb
            ConfigLoader.save(config)
            switch level {
            case .all:
                speech.announce("Dialog alerts on. Sheets and system prompts are announced.")
            case .system:
                speech.announce("Dialog alerts system only. "
                    + "Password and permission prompts are announced; app sheets are not.")
            case .off:
                speech.announce("Dialog alerts off.")
            }

        case "dialogfocus":
            guard let setting = DialogFocus.Setting(rawValue: value) else {
                return fail("Say ask, always, or off.")
            }
            setDialogFocus(setting)
            switch setting {
            case .ask:
                speech.announce("Dialog focus ask. "
                    + "Announced dialogs offer a, o, n, or s.")
            case .always:
                speech.announce("Dialog focus always. "
                    + "Announced dialogs are focused automatically.")
            case .off:
                speech.announce("Dialog focus off.")
            }

        case "hints":
            guard let on = toggle() else { return fail("Say on or off.") }
            setHints(on)
            speech.announce(on ? "Onboarding hints on."
                               : "Onboarding hints off.")

        case "follow":
            guard let on = toggle() else { return fail("Say on or off.") }
            keyboardMonitor?.followEnabled = on
            var kb = config.keyboard ?? .init()
            kb.follow = on
            config.keyboard = kb
            ConfigLoader.save(config)
            speech.announce(on ? "Follow along on. The view tracks the read."
                               : "Follow along off.")

        case "invert":
            guard let on = toggle() else { return fail("Say on or off.") }
            displayInverter?.invertEnabled = on
            if !on { displayInverter?.revertIfInverted() }
            config.display.invertEnabled = on
            ConfigLoader.save(config)
            if on && config.display.invertForApps.isEmpty
                && !(config.display.autoInvert ?? false) {
                speech.announce("Display inversion on, but no apps are listed. "
                    + "Add bundle identifiers to invert for apps in config "
                    + "dot json, or turn on auto invert.")
            } else {
                speech.announce(on ? "Display inversion on." : "Display inversion off.")
            }

        case "pdfdark":
            guard let style = DisplayInverter.PDFDarkStyle(rawValue: value) else {
                return fail("Say auto, on, or off.")
            }
            displayInverter?.pdfDarkStyle = style
            config.display.pdfDark = value
            ConfigLoader.save(config)
            displayInverter?.applyPreviewDarkModeIfFront()
            switch style {
            case .auto:
                speech.announce("P D F dark auto: dark P D Fs whenever your "
                    + "Mac is in dark mode.")
            case .on:
                speech.announce("P D F dark on. Preview documents switch to "
                    + "dark view.")
            case .off:
                speech.announce("P D F dark off.")
            }

        case "dock":
            guard let on = toggle() else { return fail("Say on or off.") }
            config.display.dockIcon = on
            ConfigLoader.save(config)
            NSApp.setActivationPolicy(on ? .regular : .accessory)
            speech.announce(on
                ? "Marduk now appears in the Dock, the app switcher, and the "
                    + "Force Quit window. Note: force quitting only restarts "
                    + "it — marduk stop, or colon quit, keeps it stopped."
                : "Marduk is hidden from the Dock and Force Quit again.")

        case "autoinvert":
            guard let on = toggle() else { return fail("Say on or off.") }
            displayInverter?.autoInvert = on
            config.display.autoInvert = on
            ConfigLoader.save(config)
            if on {
                if !CGPreflightScreenCaptureAccess() {
                    // Modern macOS often registers the app in the pane
                    // SILENTLY instead of showing a dialog — prime the
                    // registration, open the pane, and narrate the toggle
                    CGRequestScreenCaptureAccess()
                    displayInverter?.primeCapturePermission()
                    let opener = Process()
                    opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    opener.arguments = ["x-apple.systempreferences:"
                        + "com.apple.preference.security?Privacy_ScreenCapture"]
                    try? opener.run()
                    speech.announce("Auto invert on, but Marduk needs the Screen "
                        + "Recording permission first. I opened that Settings "
                        + "pane: find Marduk in the list, turn it on, and choose "
                        + "quit and reopen when macOS offers — Marduk restarts "
                        + "itself. If Marduk is not listed yet, switch apps once "
                        + "and it will appear.")
                } else {
                    speech.announce("Auto invert on. Bright apps invert, dark "
                        + "apps revert, measured as you switch.")
                }
            } else {
                speech.announce("Auto invert off.")
            }

        case "readmotions":
            guard let on = toggle() else { return fail("Say on or off.") }
            keyboardMonitor?.readMotionsEnabled = on
            var kb = config.keyboard ?? .init()
            kb.readMotions = on
            config.keyboard = kb
            ConfigLoader.save(config)
            speech.announce(on
                ? "Read motions on. During a read: b and w step words, "
                    + "parens sentences, braces paragraphs, g g start, "
                    + "capital G end, slash searches. Tap Escape to pause. "
                    + "Hold Escape, or press i, to leave the read."
                : "Read motions off.")

        case "togglesound":
            guard ["speech", "earcon"].contains(value) else {
                return fail("Toggle sound must be speech or earcon.")
            }
            keyboardMonitor?.toggleEarconEnabled = (value == "earcon")
            var kb = config.keyboard ?? .init()
            kb.toggleSound = value
            config.keyboard = kb
            ConfigLoader.save(config)
            speech.announce("Toggle sound \(value).")

        case "autoupdate":
            guard let on = toggle() else { return fail("Say on or off.") }
            autoUpdate = on
            var up = config.update ?? .init()
            up.auto = on
            config.update = up
            ConfigLoader.save(config)
            speech.announce("Auto update \(value).")

        case "checkhours":
            guard let hours = number() else {
                return fail("Check hours must be 0 to 168. Zero disables checks.")
            }
            updateCheckHours = hours
            scheduleUpdateChecks()
            var up = config.update ?? .init()
            up.checkHours = hours
            config.update = up
            ConfigLoader.save(config)
            speech.announce(hours == 0 ? "Update checks off."
                                       : "Update check every \(hours) hours.")

        default:
            let matches = ColonCommand.settings.map(\.key).filter { $0.hasPrefix(key) }
            if matches.count > 1 {
                fail("\(key) is ambiguous: \(matches.joined(separator: ", ")).")
            } else {
                fail("Unknown setting \(key). Settings are rate, pitch, level, hashes, identifiers, "
                    + "rescue, burst, escape hold, echo, command echo, palette, "
                    + "auto update, check hours, border, pointer, thickness, "
                    + "speed keys, toggle sound, read motions, dialogs, follow, "
                    + "invert, p d f dark, auto invert, dock.")
            }
        }
    }

    /// Tears down and (if any indicator is enabled) recreates the overlay
    /// from the current config — ":config border/pointer/thickness" apply
    /// live this way.
    /// Stop/start are main-queue async, so the old windows are gone before
    /// the new ones order in.
    private func rebuildOverlay() {
        modeOverlay?.stop()
        modeOverlay = ModeOverlay(config: config.overlay ?? .init())
        modeOverlay?.start()
        modeOverlay?.setMode(keyboardMonitor?.mode ?? .normal)
        modeOverlay?.setReading(keyboardMonitor?.readingCapture ?? false)
        modeOverlay?.setEnabled(keyboardMonitor?.isEnabled ?? true)
    }

    /// Current values shown in the palette's key rows ("rate — 200").
    private func settingValues() -> [String: String] {
        [
            "rate": "\(Int(speech.rate * 360)) wpm",
            "pitch": "\(Int(speech.pitch * 100)) percent",
            "level": config.verbalizer?.level ?? "most",
            "hashes": (config.verbalizer?.hashes ?? true) ? "on" : "off",
            "identifiers": (config.verbalizer?.identifiers ?? true) ? "on" : "off",
            "rescue": (keyboardMonitor?.typingRescueEnabled ?? true) ? "on" : "off",
            "burst": "\(Int((keyboardMonitor?.typingBurstThreshold ?? 0.3) * 1000)) ms",
            "escapehold": "\(Int((keyboardMonitor?.escapeHoldThreshold ?? 0.4) * 1000)) ms",
            "echo": (keyboardMonitor?.typingEchoEnabled ?? false) ? "on" : "off",
            "commandecho": (keyboardMonitor?.commandEchoEnabled ?? true) ? "on" : "off",
            "palette": paletteEnabled ? "on" : "off",
            "position": palette.positionMode.rawValue,
            "autoupdate": autoUpdate ? "on" : "off",
            "checkhours": updateCheckHours == 0 ? "off" : "\(updateCheckHours) h",
            "border": (config.overlay?.borderEnabled ?? false) ? "on" : "off",
            "pointer": (config.overlay?.pointerEnabled ?? false) ? "on" : "off",
            "thickness": "\(config.overlay?.thickness ?? 6) pt",
            "speedkeys": (keyboardMonitor?.speedKeysEnabled ?? false) ? "on" : "off",
            "togglesound": (keyboardMonitor?.toggleEarconEnabled ?? false) ? "earcon" : "speech",
            "readmotions": (keyboardMonitor?.readMotionsEnabled ?? false) ? "on" : "off",
            "dialogs": dialogSentinel.level.rawValue,
            "dialogfocus": dialogFocusSetting.rawValue,
            "hints": (config.onboarding?.hints ?? true) ? "on" : "off",
            "follow": (keyboardMonitor?.followEnabled ?? true) ? "on" : "off",
            "invert": (config.display.invertEnabled ?? false) ? "on" : "off",
            "pdfdark": config.display.pdfDark ?? "auto",
            "autoinvert": (config.display.autoInvert ?? false) ? "on" : "off",
            "dock": (config.display.dockIcon ?? false) ? "on" : "off",
        ]
    }

    private func handleCommandChange(_ buffer: String, canAutoAccept: Bool) {
        // Dmenu semantics: an unambiguous buffer acts without Enter — but
        // DEBOUNCED (~350ms after the last keystroke), so a fast typist
        // typing the whole word is never cut off mid-word (instant accept
        // on "h" would dump the "elp" of a fully-typed "help" into the
        // app). Deletions never auto-accept — removing an auto-added space
        // must not re-add it. Expansions re-enter here via
        // replaceCommandBuffer with a trailing space, which autoResolve
        // ignores, so there are no loops.
        autoAcceptTimer?.cancel()
        if canAutoAccept, case let resolution = ColonCommand.autoResolve(buffer),
           resolution != .none {
            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      self.keyboardMonitor?.mode == .command,
                      self.commandBufferSnapshot == buffer else { return }
                switch resolution {
                case .execute(let command):
                    self.keyboardMonitor?.endCommandMode()  // palette hides via onModeChange
                    self.handleColonCommand(command)
                case .expand(let expanded):
                    // Speak the completed word so audio users hear the jump
                    // (the voices picker gets its premium-download hint)
                    if let picker = ColonCommand.pickerCommands
                        .first(where: { expanded == "\($0) " }) {
                        self.announcePickerEntry(picker)
                    } else if let word = expanded.split(separator: " ").last {
                        self.speech.announce(String(word))
                    }
                    // If the user is still typing the word we just completed
                    // ("posi" → expand → they keep typing "tion"), those
                    // chars must be absorbed, not appended as garbage.
                    let typed = buffer.split(separator: " ").last.map(String.init) ?? ""
                    let full = expanded.split(separator: " ").last.map(String.init) ?? ""
                    let absorb = full.hasPrefix(typed) ? String(full.dropFirst(typed.count)) : ""
                    self.keyboardMonitor?.replaceCommandBuffer(expanded, absorbing: absorb)
                case .none:
                    break
                }
            }
            autoAcceptTimer = work
            // 600ms: slow typists must not be cut off mid-word
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
        commandBufferSnapshot = buffer
        // App rows are enumerated only while the app picker is open — a
        // disk walk on every keystroke of every command would be absurd
        let apps = buffer.hasPrefix("invertapps") ? invertAppOptions() : []
        commandCandidates = CommandCompleter.candidates(for: buffer, values: settingValues(),
                                                        voices: voiceOptions, apps: apps)
        commandSelected = 0
        if paletteEnabled {
            palette.update(buffer: buffer, candidates: commandCandidates,
                           selected: commandSelected)
        }
    }

    private func handleCommandSelect(_ delta: Int) {
        guard !commandCandidates.isEmpty else { return }
        commandSelected = (commandSelected + delta + commandCandidates.count)
            % commandCandidates.count
        if paletteEnabled {
            palette.update(buffer: commandBufferSnapshot, candidates: commandCandidates,
                           selected: commandSelected)
        }
        // Arrow browsing is deliberate — speak the selection even with echo
        // off. Voice-picker rows preview IN their own voice: the name is the
        // audition (the whole point of the picker).
        let candidate = commandCandidates[commandSelected]
        speech.announce(candidate.display, voice: previewVoice(for: candidate))
    }

    private func handleCommandTab() {
        guard commandCandidates.indices.contains(commandSelected),
              let completion = commandCandidates[commandSelected].completion else { return }
        keyboardMonitor?.replaceCommandBuffer(completion)
        // Picker rows complete to "<picker> <identifier>" — speak the
        // display name (a voice auditions in its own voice), NEVER the raw
        // identifier: reciting "com.apple.iWork.Pages" at someone is
        // exactly the bundle-ID knowledge the picker exists to remove.
        let candidate = commandCandidates[commandSelected]
        if let voice = previewVoice(for: candidate) {
            speech.announce(candidate.display, voice: voice)
        } else if ColonCommand.pickerCommands.contains(where: {
            completion.hasPrefix("\($0) ")
        }) {
            speech.announce(candidate.display)
        } else {
            speech.announce(completion.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Non-nil when the candidate is a ":voices" picker row: the voice it
    /// names, for previewing announcements in that voice.
    private func previewVoice(for candidate: CommandCompleter.Candidate) -> AVSpeechSynthesisVoice? {
        guard let completion = candidate.completion,
              completion.hasPrefix("voices "), !completion.hasSuffix(" ") else { return nil }
        return AVSpeechSynthesisVoice(identifier: String(completion.dropFirst("voices ".count)))
    }

    // MARK: - Hot Update

    private var projectDir: String? {
        // Walk up from the binary until Package.swift appears — handles the
        // bare-binary, SPM-triple, and Marduk.app layouts alike.
        Bundler.projectDir(fromExecutable: ProcessInfo.processInfo.arguments[0])
    }

    /// silent: the periodic auto-update path — no announcements at all
    /// Release/Homebrew self-update: resolve the latest tag, then
    /// download + verify + swap via ReleaseUpdater and restart. Runs on
    /// a background queue (performUpdate already dispatched). The swap
    /// keeps the bundle path, so the exit-75 relaunch applies unchanged.
    /// A verification failure is a SECURITY event — it's announced even
    /// on the silent path, once per tag (a retrying timer must not nag).
    private func performReleaseUpdate(silent: Bool) {
        func failed(_ spoken: String) {
            DispatchQueue.main.async { [self] in
                Earcon.error()
                speech.announce(spoken)
            }
        }
        let result = Self.shell("curl", "-s", "-m", "10",
                                "-H", "User-Agent: marduk",
                                "-H", "Accept: application/vnd.github+json",
                                "https://api.github.com/repos/spencer-dollahite/marduk/releases/latest",
                                cwd: "/tmp")
        guard result.status == 0,
              let release = ReleaseCheck.parseLatestRelease(result.output) else {
            if !silent { failed("Update check failed. Is the network up?") }
            return
        }
        // Anti-rollback: the codesign + pinned-requirement + spctl gates all
        // pass for a legitimately signed OLDER release, so the only thing
        // standing between a manipulated "latest" and a downgrade is this
        // strictly-newer check. An unparseable tag refuses too.
        guard ReleaseCheck.isNewer(release.tag, than: Marduk.version) else {
            fputs("[update] latest is not newer than \(Marduk.version) — "
                + "no install\n", stderr)
            if !silent {
                DispatchQueue.main.async { [self] in
                    speech.announce("Marduk is up to date.")
                }
            }
            return
        }
        guard let exec = LaunchAgent.resolvedBinaryPath(),
              let range = exec.range(of: "/Contents/MacOS/") else {
            // Bare binary without a repo — nothing we can safely swap
            if !silent {
                failed("This copy of Marduk was installed from a release. "
                    + releaseUpdateHint)
            }
            return
        }
        let liveBundle = String(exec[..<range.lowerBound])
        fputs("[update] Self-updating to \(release.tag) at \(liveBundle)\n", stderr)

        switch ReleaseUpdater.install(tag: release.tag, liveBundlePath: liveBundle) {
        case .failure(let failure):
            switch failure {
            case .verification:
                if lastVerifyFailTag != release.tag {
                    lastVerifyFailTag = release.tag
                    failed(failure.spoken)
                }
            case .install:
                if !silent { failed(failure.spoken + " " + releaseUpdateHint) }
            case .download, .mount:
                if !silent { failed(failure.spoken) }
            }
        case .success(let newExec):
            finishReleaseUpdate(newExec: newExec, tag: release.tag, silent: silent)
        }
    }

    /// Announce (unless silent), then restart into the swapped bundle —
    /// the same completion-or-12s-failsafe shape as the source channel's
    /// restart, minus migration (the bundle path never changed).
    private func finishReleaseUpdate(newExec: String, tag: String, silent: Bool) {
        let installed = LaunchAgent.isInstalled
        let restart = { [self] in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { [self] in
                LaunchAgent.truncateLog(breadcrumb:
                    "log reset — restarting after release update to \(tag)"
                    + (silent ? " (silent auto-update)" : ""))
                if installed {
                    DispatchQueue.main.async { [self] in
                        pendingExitCode = 75  // launchd relaunches the new bytes
                        running = false
                    }
                } else {
                    let daemon = Process()
                    daemon.executableURL = URL(fileURLWithPath: newExec)
                    daemon.arguments = ["start"]
                    try? daemon.run()
                    DispatchQueue.main.async { [self] in running = false }
                }
            }
        }
        DispatchQueue.main.async { [self] in
            var restarted = false
            let restartOnce = {
                guard !restarted else { return }
                restarted = true
                restart()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                if !restarted {
                    fputs("[update] announcement never completed — failsafe restart\n", stderr)
                }
                restartOnce()
            }
            if silent {
                // Tiny courtesy, user-requested: the restart blips speech
                // out for a moment, and for an assistive layer an
                // unannounced gap reads as a failure. Two words, then go.
                speech.announce("Updating.") { restartOnce() }
            } else {
                speech.announce("Marduk \(tag) installed. Restarting.") { restartOnce() }
            }
        }
    }

    /// (failures log only; success restarts without a word).
    private func performUpdate(silent: Bool = false) {
        guard !releaseInFlight else {  // backstop for the armed/socket paths
            if !silent { speech.announce("A release is running.") }
            return
        }
        updatesKnownAvailable = false
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            func failed() {
                guard !silent else { return }
                DispatchQueue.main.async { [self] in speech.announce("Update failed") }
            }

            guard let dir = projectDir else {
                fputs("[update] No project directory — release self-update\n", stderr)
                performReleaseUpdate(silent: silent)
                return
            }

            fputs("[update] Project dir: \(dir)\n", stderr)

            // git pull
            fputs("[update] Pulling...\n", stderr)
            let pull = Self.shell("git", "pull", "--ff-only", "origin", "main", cwd: dir)
            if pull.status != 0 {
                fputs("[update] Pull failed: \(pull.output)\n", stderr)
                failed()
                return
            }
            fputs("[update] \(pull.output.trimmingCharacters(in: .whitespacesAndNewlines))\n", stderr)

            // swift build
            fputs("[update] Building...\n", stderr)
            // The build pegs every core for a minute — holding the event
            // tap through that starved key delivery system-wide (field:
            // half-dead keyboard, user rebooted). Fail open for the
            // duration; keys flow raw, NORMAL commands pause briefly.
            keyboardMonitor?.beginFailOpen(reason: "self-update build")
            defer { keyboardMonitor?.endFailOpen(reason: "self-update build") }
            let build = Self.shell("swift", "build", cwd: dir)
            if build.status != 0 {
                fputs("[update] Build FAILED:\n\(build.output)\n", stderr)
                failed()
                return
            }
            if build.output.range(of: "warning:", options: .caseInsensitive) != nil {
                let count = build.output.components(separatedBy: "warning:").count - 1
                fputs("[update] Build has \(count) warning(s) — NOT reloading\n", stderr)
                failed()
                return
            }
            fputs("[update] Build clean\n", stderr)
            guard let bundleExec = Bundler.assemble(binaryPath: dir + "/.build/debug/marduk",
                                                    projectDir: dir) else {
                fputs("[update] Bundle assembly failed\n", stderr)
                failed()
                return
            }

            // Migration: the installed plist still points at the old bare
            // binary. The daemon cannot bootout itself (deadlock) — write
            // the new plist FILE, hand the rebootstrap to a detached
            // helper, and exit CLEAN so KeepAlive can't race-relaunch the
            // old path before the helper boots it out.
            let installed = LaunchAgent.isInstalled
            let migration = installed && LaunchAgent.installedProgramPath() != bundleExec

            let restart = { [self] in
                // Give unduck time to complete before restarting
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { [self] in
                    // Fresh log per build (failures above never truncate,
                    // so update-failure diagnostics survive)
                    LaunchAgent.truncateLog(breadcrumb:
                        "log reset — restarting after source update"
                        + (silent ? " (silent auto-update)" : ""))
                    if migration {
                        if LaunchAgent.writePlist(binaryPath: bundleExec) {
                            LaunchAgent.relaunchDetached()
                        }
                        DispatchQueue.main.async { [self] in running = false }  // exit 0
                    } else if installed {
                        // Exit non-zero after clean teardown; launchd
                        // relaunches the freshly built binary supervised
                        // (a Process spawn here would be an orphan).
                        DispatchQueue.main.async { [self] in
                            pendingExitCode = 75  // EX_TEMPFAIL
                            running = false
                        }
                    } else {
                        let daemon = Process()
                        daemon.executableURL = URL(fileURLWithPath: bundleExec)
                        daemon.arguments = ["start"]
                        do {
                            try daemon.run()
                        } catch {
                            fputs("[update] Failed to start new daemon: \(error)\n", stderr)
                        }
                        // Stop ourselves
                        DispatchQueue.main.async { [self] in running = false }
                    }
                }
            }

            // Announce success (unless silent), wait for speech + unduck to
            // finish, then restart. The completion is tied to this specific
            // utterance and fires on finish or cancel, so the restart can't
            // be lost to a stale didCancel or an Escape mid-announcement.
            // A migration is a one-time structural event — it speaks even
            // on the silent periodic path. FAILSAFE: a wedged speech engine
            // (whose completions never fire) once stranded fully-built
            // updates — the restart also fires on a 12s timer, whichever
            // comes first.
            DispatchQueue.main.async { [self] in
                var restarted = false
                let restartOnce = {
                    guard !restarted else { return }
                    restarted = true
                    restart()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                    if !restarted {
                        fputs("[update] announcement never completed — failsafe restart\n", stderr)
                    }
                    restartOnce()
                }
                if migration {
                    speech.announce("Update complete. Marduk is now an app "
                        + "bundle. If keyboard commands stop, grant "
                        + "Accessibility to Marduk again.") { restartOnce() }
                } else if silent {
                    // Tiny courtesy, user-requested: never blip out unannounced
                    speech.announce("Updating.") { restartOnce() }
                } else {
                    speech.announce("Update complete. Restarting.") { restartOnce() }
                }
            }
        }
    }

    private static func shell(_ args: String..., cwd: String) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = Array(args)
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (-1, "Failed to launch: \(error)")
        }

        // Drain the pipe BEFORE waiting: swift build output easily exceeds the
        // 64KB pipe buffer, and a full pipe blocks the child forever if we
        // waitUntilExit() first.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    // MARK: - Signal Handling

    private func setupSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                fputs("\n[marduk] Signal received, shutting down...\n", stderr)
                self?.running = false
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - Cleanup

    private func cleanup() {
        BootGuard.markStable()  // reaching teardown at all means no crash
        modeOverlay?.stop()
        displayInverter?.stop()
        keyboardMonitor?.stop()
        speech.stop()
        // A Firefox narration handoff pins the duck (holdActive) and is only
        // released by keyboard gestures — quitting mid-handoff would strand
        // the user's music paused forever. Idempotent when nothing is held.
        ducker.releaseHoldAndUnduckSync()
        close(serverFD)
        unlink(MardukDaemon.socketPath)
        unlink(MardukDaemon.pidPath)
        fputs("[marduk] Daemon stopped.\n", stderr)
    }
}
