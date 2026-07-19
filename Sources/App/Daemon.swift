import Foundation
import AppKit
import AVFoundation

enum MardukDaemon {
    static let socketPath = "/tmp/marduk.sock"
    static let pidPath = "/tmp/marduk.pid"
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
    private let escapeHoldThreshold: TimeInterval
    private let typingBurstThreshold: TimeInterval
    private let typingRescueEnabled: Bool

    // Retained for live mutation (":config") + persistence
    private var config: MardukConfig
    private let tutorial = Tutorial()
    private let palette = CommandPalette()
    private var paletteEnabled: Bool
    // Palette state, main-queue-only: last buffer + its completion candidates
    private var commandBufferSnapshot = ""
    private var commandCandidates: [CommandCompleter.Candidate] = []
    private var commandSelected = 0
    private var autoAcceptTimer: DispatchWorkItem?
    private var lastTipIndex = -1

    // Update checking: `u` checks + arms; a second u while armed installs.
    // The periodic timer announces once per new remote head (or installs,
    // with autoupdate on).
    private var updateArmedUntil: Date?
    private var lastAnnouncedRemote = ""
    private var autoRetryScheduled = false
    private var updateCheckTimer: DispatchSourceTimer?
    private var autoUpdate: Bool
    private var updateCheckHours: Int

    init(config: MardukConfig) {
        self.config = config
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
            targets: buildDuckTargets(from: config)
        )
        ducker = AudioDucker(config: duckerConfig)
        speech = SpeechEngine(ducker: ducker)
        speech.rate = config.speech.rate
        speech.preprocessor = SpeechPreprocessor.settings(from: config.verbalizer)

        if let voiceId = config.speech.voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: voiceId) {
            speech.voice = voice
        }

        displayInverter = DisplayInverter(invertApps: config.display.invertForApps)
    }

    func run() throws {
        // A client that disconnects before we write its response would
        // otherwise kill the whole daemon with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)

        let pid = ProcessInfo.processInfo.processIdentifier
        try "\(pid)".write(toFile: MardukDaemon.pidPath, atomically: true, encoding: .utf8)

        unlink(MardukDaemon.socketPath)

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
        NSApp.setActivationPolicy(.accessory)

        tutorial.announce = { [self] text in speech.announce(text) }

        // Start keyboard monitor (Option+Escape → speak selection)
        keyboardMonitor = KeyboardMonitor()
        keyboardMonitor?.escapeHoldThreshold = escapeHoldThreshold
        keyboardMonitor?.typingBurstThreshold = typingBurstThreshold
        keyboardMonitor?.typingRescueEnabled = typingRescueEnabled
        keyboardMonitor?.typingEchoEnabled = config.keyboard?.typingEcho ?? false
        keyboardMonitor?.commandEchoEnabled = config.keyboard?.commandEcho ?? true
        palette.positionMode = CommandPalette.PositionMode(
            rawValue: config.keyboard?.palettePosition ?? "center") ?? .center
        // Tutorial events ride the existing callbacks: reads complete via the
        // per-utterance completion, announcements and pause toggles are
        // interposed here. The tutorial's own narration goes straight to
        // speech.announce (tutorial.announce above), so it never sees itself.
        keyboardMonitor?.start(
            onSpeak: { [self] text in
                speech.speak(text) { [self] in tutorial.handle(.readFinished) }
            },
            onStop: { [self] in speech.stop() },
            onAnnounce: { [self] text in
                tutorial.handle(.announced(text))
                speech.announce(text)
            },
            onUpdate: { [self] in performUpdate() },
            isSpeaking: { [self] in speech.isSpeaking },
            isReadActive: { [self] in speech.readActive },
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
                if mode != .command {
                    palette.hide()
                    autoAcceptTimer?.cancel()
                }
            }
        }
        keyboardMonitor?.onEnabledChange = { [self] enabled in
            DispatchQueue.main.async { [self] in
                if !enabled {
                    tutorial.abort(silent: true)
                    palette.hide()
                }
            }
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
        // Clicking a palette row acts like Tab on that row (mouseDown arrives
        // on the main thread already)
        palette.onRowClick = { [self] row in
            guard commandCandidates.indices.contains(row) else { return }
            commandSelected = row
            handleCommandTab()
        }
        scheduleUpdateChecks()

        displayInverter?.start()

        // First-run welcome: marker written immediately so a crash mid-speech
        // can never replay-loop it. Spoken via the READ path — Space-pausable,
        // Escape-stoppable. (If tap creation failed, this replaces the queued
        // permission announcement; the tap retry re-announces on success.)
        let welcomeMarker = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/marduk/.welcomed")
        if !FileManager.default.fileExists(atPath: welcomeMarker.path) {
            DispatchQueue.main.async { [self] in
                try? Data().write(to: welcomeMarker)
                fputs("[marduk] first-run welcome\n", stderr)
                speech.speak(HelpText.welcome)
            }
        }

        fputs("[marduk] Daemon running (PID \(pid))\n", stderr)
        fputs("[marduk] Socket: \(MardukDaemon.socketPath)\n", stderr)

        // Main RunLoop — needed for AVSpeechSynthesizer + CGEventTap callbacks
        while running {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }

        // Stop event tap first to prevent callbacks during teardown
        keyboardMonitor?.stop()
        // Drain pending callbacks
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        cleanup()
        if pendingExitCode != 0 {
            exit(pendingExitCode)
        }
    }

    // MARK: - Client Handling

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }

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

        fputs("[marduk] cmd: \(cmd)", stderr)
        if !arg.isEmpty { fputs(" \(arg.prefix(80))", stderr) }
        fputs("\n", stderr)

        switch cmd {
        case "ping":
            return "OK pong\n"
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
            } else {
                keyboardMonitor?.endCommandMode()
                handleColonCommand(completion)
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
        case .quit:
            // Clean exit 0 — under launchd (SuccessfulExit=false) this stays
            // stopped until next login or `marduk start`.
            speech.announce("Marduk stopping.") { [self] in
                DispatchQueue.main.async { [self] in running = false }
            }
        case .restart:
            speech.announce("Restarting.") { [self] in
                DispatchQueue.main.async { [self] in
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
                + "They contain text Marduk has spoken — review before pasting.")
        case .feedback:
            speech.announce("Opening GitHub issues. If you paste log lines, "
                + "remember they contain text Marduk has spoken.")
            openURL("https://github.com/spencer-dollahite/marduk/issues/new/choose")
        case .bug:
            speech.announce("Opening a bug report. If you paste log lines, "
                + "remember they contain text Marduk has spoken.")
            openURL("https://github.com/spencer-dollahite/marduk/issues/new?template=bug_report.md")
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

    private enum UpdateCheckOrigin { case manual, periodic }

    /// Single `u`: install if a check is armed, else check + speak notes.
    /// (Fast `uu` bypasses this — the burst layer calls performUpdate directly.)
    private func handleUpdateKey() {
        if let until = updateArmedUntil, Date() < until {
            updateArmedUntil = nil
            speech.announce("Update initiated")
            performUpdate()
            return
        }
        checkForUpdates(origin: .manual)
    }

    /// Fetches origin/main off the main thread and reports what's new.
    private func checkForUpdates(origin: UpdateCheckOrigin) {
        guard let dir = projectDir else {
            if origin == .manual {
                Earcon.error()
                speech.announce("Cannot find the project directory.")
            }
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
            DispatchQueue.main.async { [self] in
                handleCheckResult(subjects: subjects, remote: remote, origin: origin)
            }
        }
    }

    private func handleCheckResult(subjects: [String], remote: String,
                                   origin: UpdateCheckOrigin) {
        guard !subjects.isEmpty else {
            if origin == .manual { speech.announce("Marduk is up to date.") }
            return
        }
        fputs("[update] \(subjects.count) update(s) available\n", stderr)
        switch origin {
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
            text += ". Press u again to install."
            speech.speak(text)
        case .periodic:
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
        let displays = commandCandidates.map(\.display)
        if displays.isEmpty {
            if explicit { speech.announce("No options here. Press Return to run it.") }
            return
        }
        speech.speak("Options: " + displays.joined(separator: ", ") + ".")
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
            // READ voice on purpose: the confirmation demos the new rate
            speech.speak("Rate set to \(wpm) words per minute.")

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
                fail("Unknown setting \(key). Settings are rate, level, hashes, "
                    + "rescue, burst, escape hold, echo, command echo, palette, "
                    + "auto update, check hours.")
            }
        }
    }

    /// Current values shown in the palette's key rows ("rate — 200").
    private func settingValues() -> [String: String] {
        [
            "rate": "\(Int(speech.rate * 360)) wpm",
            "level": config.verbalizer?.level ?? "most",
            "hashes": (config.verbalizer?.hashes ?? true) ? "on" : "off",
            "rescue": (keyboardMonitor?.typingRescueEnabled ?? true) ? "on" : "off",
            "burst": "\(Int((keyboardMonitor?.typingBurstThreshold ?? 0.3) * 1000)) ms",
            "escapehold": "\(Int((keyboardMonitor?.escapeHoldThreshold ?? 0.4) * 1000)) ms",
            "echo": (keyboardMonitor?.typingEchoEnabled ?? false) ? "on" : "off",
            "commandecho": (keyboardMonitor?.commandEchoEnabled ?? true) ? "on" : "off",
            "palette": paletteEnabled ? "on" : "off",
            "position": palette.positionMode.rawValue,
            "autoupdate": autoUpdate ? "on" : "off",
            "checkhours": updateCheckHours == 0 ? "off" : "\(updateCheckHours) h",
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
                    if let word = expanded.split(separator: " ").last {
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
        commandCandidates = CommandCompleter.candidates(for: buffer, values: settingValues())
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
        // Arrow browsing is deliberate — speak the selection even with echo off
        speech.announce(commandCandidates[commandSelected].display)
    }

    private func handleCommandTab() {
        guard commandCandidates.indices.contains(commandSelected),
              let completion = commandCandidates[commandSelected].completion else { return }
        keyboardMonitor?.replaceCommandBuffer(completion)
        speech.announce(completion.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Hot Update

    private var projectDir: String? {
        // Walk up from the binary until Package.swift appears. The depth
        // varies: .build/debug/marduk from a terminal, but the launchd plist
        // stores the resolved .build/arm64-apple-macosx/debug/marduk.
        var url = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).standardized
        for _ in 0..<6 where url.path != "/" {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Package.swift").path) {
                return url.path
            }
        }
        return nil
    }

    /// silent: the periodic auto-update path — no announcements at all
    /// (failures log only; success restarts without a word).
    private func performUpdate(silent: Bool = false) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            func failed() {
                guard !silent else { return }
                DispatchQueue.main.async { [self] in speech.announce("Update failed") }
            }

            guard let dir = projectDir else {
                fputs("[update] Cannot find project directory\n", stderr)
                failed()
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
            Codesign.sign(binaryAt: dir + "/.build/debug/marduk")

            let restart = { [self] in
                // Give unduck time to complete before restarting
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { [self] in
                    if LaunchAgent.isInstalled {
                        // Exit non-zero after clean teardown; launchd
                        // relaunches the freshly built binary supervised
                        // (a Process spawn here would be an orphan).
                        DispatchQueue.main.async { [self] in
                            pendingExitCode = 75  // EX_TEMPFAIL
                            running = false
                        }
                    } else {
                        let binary = dir + "/.build/debug/marduk"
                        let daemon = Process()
                        daemon.executableURL = URL(fileURLWithPath: binary)
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
            DispatchQueue.main.async { [self] in
                if silent {
                    restart()
                } else {
                    speech.announce("Update complete. Restarting.") { restart() }
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
        displayInverter?.stop()
        keyboardMonitor?.stop()
        speech.stop()
        close(serverFD)
        unlink(MardukDaemon.socketPath)
        unlink(MardukDaemon.pidPath)
        fputs("[marduk] Daemon stopped.\n", stderr)
    }
}
