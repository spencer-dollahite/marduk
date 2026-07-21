import Foundation
import ApplicationServices
import AVFoundation

// MARK: - Marduk: Assistive Technology Platform for macOS

func printUsage() {
    fputs("""

        ███╗   ███╗
        ████╗ ████║
        ██╔████╔██║
        ██║╚██╔╝██║   Marduk — Assistive Technology Platform for macOS
        ██║ ╚═╝ ██║
        ╚═╝     ╚═╝

    Usage:
      marduk start [--foreground] [--debug]
                                   Start daemon (via launchd if installed;
                                   --foreground runs inline, --debug implies it)
      marduk stop                  Stop running daemon
      marduk status                Daemon, launch agent, and log status
      marduk install               Install launchd agent (autostart at login,
                                   restart on crash, log to ~/Library/Logs/marduk.log)
      marduk uninstall             Remove the launchd agent
      marduk update                Git pull, build, hot-reload daemon (run from project dir)
      marduk speak <text>          Speak text (forwards to daemon if running)
      marduk speak --stdin         Read text from stdin and speak it
      marduk config                Show current configuration
      marduk config --reset        Reset configuration to defaults
      marduk config rate <wpm>     Set speech rate (50-360 words per minute)
      marduk duck                  Duck external audio (manual trigger)
      marduk unduck                Restore external audio (manual trigger)
      marduk audio-debug           Dump audio-producing PIDs + Firefox AX tab tree
      marduk voices [--test]       List available TTS voices (--test: interactive tester)
      marduk version               Show version

    Files:
      ~/.config/marduk/config.json                   Configuration
      ~/Library/Logs/marduk.log                      Daemon log (agent installs only)
      ~/Library/LaunchAgents/com.marduk.daemon.plist Launch agent

    Examples:
      marduk start                 Start daemon in one terminal
      marduk speak "Hello world"   Send speech from another terminal
      marduk update                Pull + rebuild + hot-reload daemon

    """, stderr)
}

func printVersion() {
    print("Marduk \(Marduk.version) (Daemon Mode)")
}

func listVoices() {
    let voices = AVSpeechSynthesisVoice.speechVoices()
        .filter { $0.language.hasPrefix("en") }
        .sorted { a, b in
            if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
            return a.name < b.name
        }

    print("Available English voices:")
    for voice in voices {
        let quality: String
        switch voice.quality {
        case .premium: quality = "premium"
        case .enhanced: quality = "enhanced"
        default: quality = "default"
        }
        let marker = voice.quality == .enhanced || voice.quality == .premium ? " *" : ""
        print("  \(voice.name) (\(voice.language), \(quality))\(marker)")
    }
    print("\n  * = recommended (download in System Settings > Accessibility > Spoken Content)")
}

private class VoiceTesterState: @unchecked Sendable {
    var pendingInput: String?
    var quit = false
}

func testVoices() {
    let voices = AVSpeechSynthesisVoice.speechVoices()
        .filter { $0.language.hasPrefix("en") }
        .sorted { a, b in
            if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
            return a.name < b.name
        }

    let synth = AVSpeechSynthesizer()
    let sample = "Systems engaged. Update initiated."
    let state = VoiceTesterState()
    var i = 0

    func qualityLabel(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: return "premium"
        case .enhanced: return "enhanced"
        default: return "default"
        }
    }

    func playVoice(_ index: Int) {
        let v = voices[index]
        print("  [\(index + 1)/\(voices.count)] \(v.name) (\(v.language), \(qualityLabel(v)))")

        let utterance = AVSpeechUtterance(string: sample)
        utterance.voice = v
        utterance.rate = 0.45
        utterance.pitchMultiplier = 0.9

        synth.speak(utterance)
    }

    // Read stdin on background thread so main RunLoop stays free for speech
    DispatchQueue.global(qos: .userInteractive).async {
        while !state.quit {
            print("  > ", terminator: "")
            fflush(stdout)
            guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                state.pendingInput = "q"
                return
            }
            state.pendingInput = line
        }
    }

    print("Voice tester — \(voices.count) English voices")
    print("  Enter = next, p = previous, r = replay, q = quit\n")

    playVoice(i)

    // Main loop: pump RunLoop for speech, check for input
    while !state.quit {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))

        guard let input = state.pendingInput else { continue }
        state.pendingInput = nil

        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }

        switch input {
        case "", "n":
            i += 1
            if i >= voices.count {
                print("\n  That's all the voices.")
                i = voices.count - 1
            } else {
                playVoice(i)
            }
        case "p":
            i = max(0, i - 1)
            playVoice(i)
        case "r":
            playVoice(i)
        case "q":
            state.quit = true
            print("\n  Current voice: \(voices[i].name) (\(voices[i].identifier))")
        default:
            print("  Enter = next, p = previous, r = replay, q = quit")
        }
    }
}

func showConfig(_ config: MardukConfig) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(config),
       let json = String(data: data, encoding: .utf8) {
        print(json)
    }
}

// MARK: - Main

let args = CommandLine.arguments
let config = ConfigLoader.load()

// Double-clicking Marduk.app in Finder launches the executable with no
// arguments — for a release install that must BE the installer: the
// friendliest possible onboarding is download, drag, double-click, and
// follow the voice. Bare-binary no-args invocations keep printing usage.
let launchedFromFinder = args.count < 2
    && (LaunchAgent.resolvedBinaryPath() ?? "").contains("/Marduk.app/Contents/MacOS/")

let command: String
if args.count >= 2 {
    command = args[1]
} else if launchedFromFinder {
    command = "install"
} else {
    printUsage()
    exit(1)
}

switch command {
case "version", "--version", "-v":
    printVersion()

case "voices":
    if args.count >= 3 && args[2] == "--test" {
        testVoices()
    } else {
        listVoices()
    }

case "config":
    if args.count >= 3 && args[2] == "--reset" {
        ConfigLoader.save(MardukConfig())
        print("Configuration reset to defaults.")
    } else if args.count >= 4 && args[2] == "rate" {
        guard let wpm = Int(args[3]), wpm >= 50, wpm <= 360 else {
            fputs("Usage: marduk config rate <50-360>  (words per minute)\n", stderr)
            exit(1)
        }
        let rate = Float(wpm) / 360.0
        var updated = config
        updated.speech.rate = rate
        ConfigLoader.save(updated)
        if DaemonClient.isRunning {
            DaemonClient.send("rate \(rate)")
        }
        print("Speech rate set to \(wpm) WPM")
    } else {
        showConfig(config)
    }

case "start":
    if DaemonClient.isRunning {
        // Exit 0: under launchd's KeepAlive, a non-zero exit from the
        // agent-spawned instance would relaunch-loop forever against
        // whichever daemon holds the socket.
        print("Marduk daemon is already running.")
        exit(0)
    }

    let foreground = args.contains("--foreground") || args.contains("--debug")
    if LaunchAgent.isInstalled && !foreground {
        guard LaunchAgent.kickstart() else { exit(1) }
        var ready = false
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            if DaemonClient.isRunning { ready = true; break }
        }
        if ready {
            print("Marduk daemon started via launchd. Log: \(LaunchAgent.logPath)")
        } else {
            fputs("WARNING: daemon did not come up — check \(LaunchAgent.logPath)\n", stderr)
            exit(1)
        }
        exit(0)
    }

    if args.contains("--debug") {
        AudioDucker.debug = true
    }

    let server = DaemonServer(config: config)
    do {
        try server.run()
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

case "stop":
    if DaemonClient.isRunning {
        DaemonClient.send("stop")
        print("Marduk daemon stopped.")
        if LaunchAgent.isInstalled {
            print("Agent stays installed — daemon returns at next login or 'marduk start'.")
        }
    } else {
        print("Marduk daemon is not running.")
    }

case "status":
    // Socket ping is the source of truth; the pid file is validated, not trusted.
    var daemonLine = "not running"
    if DaemonClient.isRunning {
        daemonLine = "running"
        if let pidStr = try? String(contentsOfFile: MardukDaemon.pidPath, encoding: .utf8),
           let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
            daemonLine += kill(pid, 0) == 0 ? " (PID \(pid))" : " (stale pid file)"
        }
    } else if FileManager.default.fileExists(atPath: MardukDaemon.pidPath) {
        daemonLine = "not running (stale pid file)"
    }
    print("Daemon:  \(daemonLine)")
    if LaunchAgent.isInstalled {
        print("Agent:   installed (\(LaunchAgent.label))")
        print("launchd: \(LaunchAgent.state() ?? "not loaded")")
        var logLine = LaunchAgent.logPath
        if let attrs = try? FileManager.default.attributesOfItem(atPath: LaunchAgent.logPath),
           let size = attrs[.size] as? UInt64 {
            logLine += String(format: " (%.1f MB)", Double(size) / 1_048_576)
        }
        print("Log:     \(logLine)")
    } else {
        print("Agent:   not installed — run 'marduk install' for login autostart")
    }
    // Karabiner is assumed (button routing, macOS-fallback handoff) but
    // never required — surface which mode this machine is in
    let keCLI = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
    if FileManager.default.isExecutableFile(atPath: keCLI) {
        print("Karabiner: installed (profile handoff active)")
    } else {
        print("Karabiner: not found — read-button routing and automatic macOS fallback inactive")
    }

case "install":
    guard let binary = LaunchAgent.resolvedBinaryPath() else {
        fputs("Error: cannot resolve the marduk binary path.\n", stderr)
        exit(1)
    }
    // Double-click on an already-running install: reassure, don't reinstall
    if launchedFromFinder && DaemonClient.isRunning {
        DaemonClient.send("speak Marduk is already installed and running.")
        exit(0)
    }
    let reinstall = LaunchAgent.isInstalled

    // Assemble Marduk.app and install THAT — the bundle carries the stable
    // TCC identity, the icon, and the usage descriptions. Fall back to the
    // bare binary only when no project directory can be found (binary
    // copied out of the repo). Bundle-ness is detected, never assumed.
    let installTarget: String
    if binary.contains("/Marduk.app/Contents/MacOS/"),
       Bundler.projectDir(fromExecutable: binary) == nil {
        // Running from a RELEASE bundle (e.g. /Applications/Marduk.app):
        // install as-is — reassembling or re-signing would destroy the
        // notarized Developer ID signature, and release users have no
        // certificate anyway.
        installTarget = binary
    } else if let dir = Bundler.projectDir(fromExecutable: binary)
        ?? (FileManager.default.fileExists(atPath: "Package.swift")
                ? FileManager.default.currentDirectoryPath : nil),
       let bundleExec = Bundler.assemble(binaryPath: binary, projectDir: dir) {
        installTarget = bundleExec
    } else {
        fputs("WARNING: no project directory — installing the bare binary "
            + "(no bundle, TCC-fragile).\n", stderr)
        // Safe even though install runs FROM this binary — sign() swaps in
        // a signed copy; the running process keeps the old inode.
        Codesign.sign(binaryAt: binary)
        installTarget = binary
    }

    // A foreground daemon holds the socket, which would make the launchd
    // instance exit at startup — stop it first.
    if DaemonClient.isRunning {
        print("Stopping running daemon...")
        DaemonClient.send("stop")
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.25)
            if !DaemonClient.isRunning { break }
        }
    }
    guard LaunchAgent.install(binaryPath: installTarget) else { exit(1) }
    var ready = false
    for _ in 0..<20 {
        Thread.sleep(forTimeInterval: 0.25)
        if DaemonClient.isRunning { ready = true; break }
    }
    print("\(reinstall ? "Reinstalled" : "Installed") launch agent \(LaunchAgent.label)")
    print("  binary: \(installTarget)")
    print("  log:    \(LaunchAgent.logPath)")
    if ready {
        print("Daemon is running under launchd.")
    } else {
        fputs("WARNING: daemon did not come up — check the log.\n", stderr)
        exit(1)
    }
    // Finder-launched install with no Accessibility grant yet: the daemon
    // is announcing what to do out loud — put the right Settings pane in
    // front of the user while it talks.
    if launchedFromFinder && !AXIsProcessTrusted() {
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]
        try? opener.run()
    }

case "bundle":
    // Internal: assemble Marduk.app from this binary and print its
    // executable path (used by scripts/release.sh with the release build)
    guard let bundleBinary = LaunchAgent.resolvedBinaryPath(),
          let bundleProjectDir = Bundler.projectDir(fromExecutable: bundleBinary)
            ?? (FileManager.default.fileExists(atPath: "Package.swift")
                    ? FileManager.default.currentDirectoryPath : nil) else {
        fputs("Error: cannot resolve the binary or project directory.\n", stderr)
        exit(1)
    }
    guard let assembled = Bundler.assemble(binaryPath: bundleBinary,
                                           projectDir: bundleProjectDir) else {
        exit(1)
    }
    print(assembled)

case "uninstall":
    if LaunchAgent.isInstalled {
        LaunchAgent.uninstall()
        print("Launch agent removed; daemon stopped. Log left at \(LaunchAgent.logPath)")
    } else {
        print("Launch agent not installed.")
    }

case "update":
    guard FileManager.default.fileExists(atPath: "Package.swift") else {
        fputs("Error: Run 'marduk update' from the project directory.\n", stderr)
        exit(1)
    }

    fputs("[update] Pulling...\n", stderr)
    let pull = runShell("git", "pull", "--ff-only", "origin", "main")
    if pull.status != 0 {
        fputs("[update] Pull failed:\n\(pull.output)\n", stderr)
        exit(1)
    }
    fputs("[update] \(pull.output.trimmingCharacters(in: .whitespacesAndNewlines))\n", stderr)

    fputs("[update] Building...\n", stderr)
    let build = runShell("swift", "build")
    if build.status != 0 {
        fputs("[update] Build FAILED:\n\(build.output)\n", stderr)
        exit(1)
    }
    if build.output.range(of: "warning:", options: .caseInsensitive) != nil {
        let count = build.output.components(separatedBy: "warning:").count - 1
        fputs("[update] Build has \(count) warning(s) — NOT reloading\n", stderr)
        fputs(build.output, stderr)
        exit(1)
    }
    fputs("[update] Build clean\n", stderr)
    let updateCwd = FileManager.default.currentDirectoryPath
    guard let updateBundleExec = Bundler.assemble(
        binaryPath: updateCwd + "/.build/debug/marduk", projectDir: updateCwd) else {
        fputs("[update] Bundle assembly failed\n", stderr)
        exit(1)
    }

    if DaemonClient.isRunning {
        fputs("[update] Stopping old daemon...\n", stderr)
        DaemonClient.send("reload")
        // Wait for old daemon to exit
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.25)
            if !DaemonClient.isRunning { break }
        }
    }

    fputs("[update] Starting new daemon...\n", stderr)
    // Fresh log per build; failures above never truncate. The breadcrumb
    // is the new log's first line — the restart must explain itself.
    LaunchAgent.truncateLog(breadcrumb: "log reset — restarting after CLI update")
    if LaunchAgent.isInstalled {
        if LaunchAgent.installedProgramPath() != updateBundleExec {
            // Migration: the plist still points at the old bare binary.
            // Synchronous bootout/bootstrap is SAFE here — the CLI is not
            // the daemon.
            fputs("[update] Migrating launch agent to \(updateBundleExec)\n", stderr)
            guard LaunchAgent.install(binaryPath: updateBundleExec) else { exit(1) }
        } else {
            // kickstart -k if the old daemon ignored the reload — kill +
            // restart under launchd either way, so the new binary stays
            // supervised.
            LaunchAgent.kickstart(kill: DaemonClient.isRunning)
        }
    } else {
        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: updateBundleExec)
        daemon.arguments = ["start"]
        do {
            try daemon.run()
        } catch {
            fputs("[update] Failed to start daemon: \(error)\n", stderr)
            exit(1)
        }
    }

    // Wait for it to come up
    var ready = false
    for _ in 0..<20 {
        Thread.sleep(forTimeInterval: 0.25)
        if DaemonClient.isRunning { ready = true; break }
    }
    fputs(ready ? "[update] Daemon restarted\n" : "[update] WARNING: daemon may not have started\n", stderr)

case "duck":
    if DaemonClient.isRunning {
        DaemonClient.send("duck")
        print("Ducked via daemon.")
    } else {
        AudioDucker.debug = true
        let duckerConfig = AudioDucker.Config(
            duckLevel: config.ducking.duckLevel,
            rampSteps: config.ducking.rampSteps,
            rampDurationMs: config.ducking.rampDurationMs,
            targets: buildDuckTargets(from: config),
            extraMediaKeyApps: config.ducking.mediaKeyApps ?? []
        )
        let ducker = AudioDucker(config: duckerConfig)
        ducker.duck()
        Thread.sleep(forTimeInterval: 2.0)
        print("Audio ducked to \(config.ducking.duckLevel)%. Press Enter to restore...")
        _ = readLine()
        ducker.unduck()
        Thread.sleep(forTimeInterval: 2.0)
        print("Audio restored.")
    }

case "audio-debug":
    AudioDiagnostics.dump()

case "unduck":
    if DaemonClient.isRunning {
        DaemonClient.send("unduck")
        print("Unducked via daemon.")
    } else {
        let ducker = AudioDucker()
        ducker.unduck()
        print("Audio restore attempted.")
    }

case "speak":
    var text: String
    var speechRate = config.speech.rate

    // Parse flags
    var textArgs: [String] = []
    var debugMode = false
    var i = 2
    while i < args.count {
        if args[i] == "--debug" {
            debugMode = true
            AudioDucker.debug = true
            i += 1
            continue
        } else if args[i] == "--stdin" {
            var stdinText = ""
            while let line = readLine(strippingNewline: false) {
                stdinText += line
            }
            textArgs.append(stdinText)
        } else if args[i] == "--rate", i + 1 < args.count {
            i += 1
            speechRate = Float(args[i]) ?? config.speech.rate
        } else {
            textArgs.append(args[i])
        }
        i += 1
    }

    text = textArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

    guard !text.isEmpty else {
        fputs("Error: No text provided. Use 'marduk speak <text>' or 'marduk speak --stdin'\n", stderr)
        exit(1)
    }

    // Forward to daemon if running
    if DaemonClient.isRunning {
        if let response = DaemonClient.send("speak \(text)") {
            if debugMode { fputs("[main] daemon: \(response)\n", stderr) }
        } else {
            fputs("Error: daemon not responding\n", stderr)
            exit(1)
        }
    } else {
        // Inline mode (no daemon)
        let duckerConfig = AudioDucker.Config(
            duckLevel: config.ducking.duckLevel,
            rampSteps: config.ducking.rampSteps,
            rampDurationMs: config.ducking.rampDurationMs,
            targets: buildDuckTargets(from: config),
            extraMediaKeyApps: config.ducking.mediaKeyApps ?? []
        )

        let ducker = AudioDucker(config: duckerConfig)
        let speech = SpeechEngine(ducker: ducker)
        speech.rate = speechRate
        speech.preprocessor = SpeechPreprocessor.settings(from: config.verbalizer)

        if let voiceId = config.speech.voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: voiceId) {
            speech.voice = voice
        }

        let done = DispatchSemaphore(value: 0)

        if debugMode {
            fputs("[main] targets: \(buildDuckTargets(from: config).map { $0.displayName })\n", stderr)
            fputs("[main] duck level: \(config.ducking.duckLevel)%\n", stderr)
            fputs("[main] speaking: \(text.prefix(80))...\n", stderr)
        }

        // Completion fires on finish OR cancel, so this can't wait forever
        speech.speak(text) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                done.signal()
            }
        }

        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }

default:
    fputs("Unknown command: \(command)\n", stderr)
    printUsage()
    exit(1)
}

// MARK: - Helpers

func runShell(_ args: String...) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = Array(args)

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

func buildDuckTargets(from config: MardukConfig) -> [AudioDucker.DuckTarget] {
    var targets: [AudioDucker.DuckTarget] = []
    if config.ducking.useMediaKey { targets.append(.mediaKey) }
    if config.ducking.duckAppleMusic { targets.append(.appleMusic) }
    if config.ducking.duckSpotify { targets.append(.spotify) }
    return targets
}
