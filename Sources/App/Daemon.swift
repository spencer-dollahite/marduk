import Foundation
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

    init(config: MardukConfig) {
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

        // Start keyboard monitor (Option+Escape → speak selection)
        keyboardMonitor = KeyboardMonitor()
        keyboardMonitor?.escapeHoldThreshold = escapeHoldThreshold
        keyboardMonitor?.typingBurstThreshold = typingBurstThreshold
        keyboardMonitor?.typingRescueEnabled = typingRescueEnabled
        keyboardMonitor?.start(
            onSpeak: { [self] text in speech.speak(text) },
            onStop: { [self] in speech.stop() },
            onAnnounce: { [self] text in speech.announce(text) },
            onUpdate: { [self] in performUpdate() },
            isSpeaking: { [self] in speech.isSpeaking },
            isReadActive: { [self] in speech.readActive },
            onPauseToggle: { [self] in speech.togglePause() }
        )

        displayInverter?.start()

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
