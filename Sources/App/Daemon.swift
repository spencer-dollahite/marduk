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
    private var lastTipIndex = -1

    init(config: MardukConfig) {
        self.config = config
        paletteEnabled = config.keyboard?.commandPalette ?? true
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
                if mode != .command { palette.hide() }
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
        keyboardMonitor?.onCommandChange = { [self] buffer in handleCommandChange(buffer) }
        keyboardMonitor?.onCommandTab = { [self] in handleCommandTab() }
        keyboardMonitor?.onCommandSelect = { [self] delta in handleCommandSelect(delta) }
        keyboardMonitor?.onCommandHelp = { [self] in speakCommandOptions(explicit: true) }
        keyboardMonitor?.onCommandIdle = { [self] in speakCommandOptions(explicit: false) }

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

        default:
            let matches = ColonCommand.settings.map(\.key).filter { $0.hasPrefix(key) }
            if matches.count > 1 {
                fail("\(key) is ambiguous: \(matches.joined(separator: ", ")).")
            } else {
                fail("Unknown setting \(key). Settings are rate, level, hashes, "
                    + "rescue, burst, escape hold, echo, command echo, palette.")
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
        ]
    }

    private func handleCommandChange(_ buffer: String) {
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

    private func performUpdate() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard let dir = projectDir else {
                fputs("[update] Cannot find project directory\n", stderr)
                DispatchQueue.main.async { [self] in speech.announce("Update failed") }
                return
            }

            fputs("[update] Project dir: \(dir)\n", stderr)

            // git pull
            fputs("[update] Pulling...\n", stderr)
            let pull = Self.shell("git", "pull", "--ff-only", "origin", "main", cwd: dir)
            if pull.status != 0 {
                fputs("[update] Pull failed: \(pull.output)\n", stderr)
                DispatchQueue.main.async { [self] in speech.announce("Update failed") }
                return
            }
            fputs("[update] \(pull.output.trimmingCharacters(in: .whitespacesAndNewlines))\n", stderr)

            // swift build
            fputs("[update] Building...\n", stderr)
            let build = Self.shell("swift", "build", cwd: dir)
            if build.status != 0 {
                fputs("[update] Build FAILED:\n\(build.output)\n", stderr)
                DispatchQueue.main.async { [self] in speech.announce("Update failed") }
                return
            }
            if build.output.range(of: "warning:", options: .caseInsensitive) != nil {
                let count = build.output.components(separatedBy: "warning:").count - 1
                fputs("[update] Build has \(count) warning(s) — NOT reloading\n", stderr)
                DispatchQueue.main.async { [self] in speech.announce("Update failed") }
                return
            }
            fputs("[update] Build clean\n", stderr)
            Codesign.sign(binaryAt: dir + "/.build/debug/marduk")

            // Announce success, wait for speech + unduck to finish, then restart.
            // The completion is tied to this specific utterance and fires on
            // finish or cancel, so the restart can't be lost to a stale
            // didCancel or a user pressing Escape mid-announcement.
            DispatchQueue.main.async { [self] in
                speech.announce("Update complete. Restarting.") { [self] in
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
