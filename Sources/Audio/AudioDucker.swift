import Foundation
import AppKit  // NSEvent for media key simulation
import CoreAudio
import Darwin  // proc_pidpath / MAXPATHLEN for PID -> executable path resolution

/// Controls external app audio volume for ducking during speech.
/// Priority: Firefox/browser (system volume) > Apple Music > Spotify > system-wide fallback.
final class AudioDucker {
    struct Config {
        var duckLevel: Int = 5           // 0-100, target volume while ducked
        var rampSteps: Int = 15          // number of steps in the ramp
        var rampDurationMs: Int = 600    // total ramp time in milliseconds
        var targets: [DuckTarget] = DuckTarget.allCases.map { $0 }
    }

    enum DuckTarget: CaseIterable, Hashable {
        case appleMusic
        case spotify
        case mediaKey   // browser/system audio: system-volume duck for Firefox YouTube Music, else media-key pause

        var displayName: String {
            switch self {
            case .appleMusic: return "Apple Music"
            case .spotify: return "Spotify"
            case .mediaKey: return "Browser/System Audio"
            }
        }

        var appName: String? {
            switch self {
            case .appleMusic: return "Music"
            case .spotify: return "Spotify"
            case .mediaKey: return nil
            }
        }
    }

    private enum PlaybackState: CustomStringConvertible {
        case playing, paused, stopped, unknown

        var description: String {
            switch self {
            case .playing: return "playing"
            case .paused: return "paused"
            case .stopped: return "stopped"
            case .unknown: return "unknown"
            }
        }
    }

    static var debug = false

    private var config: Config
    private var originalVolumes: [DuckTarget: Int] = [:]
    private var duckedTargets: Set<DuckTarget> = []
    private var cachedPlaybackStates: [DuckTarget: PlaybackState] = [:]
    private let queue = DispatchQueue(label: "com.marduk.audioducker")

    init(config: Config = Config()) {
        self.config = config
    }

    private func log(_ msg: String) {
        if AudioDucker.debug {
            fputs("[ducker] \(msg)\n", stderr)
        }
    }

    // MARK: - Public API

    /// Probe playback state BEFORE speech audio starts.
    ///
    /// Only the CoreAudio-based .mediaKey probe must run synchronously here,
    /// before synthesizer.speak(), so it isn't contaminated by our own speech
    /// output. The Apple Music / Spotify probes launch osascript (hundreds of
    /// milliseconds each) and query app state that speech can't contaminate —
    /// those are deferred to duck() on the ducker queue, so they never stall
    /// the caller (the main thread, which also services the keyboard tap).
    /// The cache store is queue.async, which is ordered before duck()'s
    /// queue.async on the same serial queue.
    func prepareToDuck() {
        let mediaKeyState: PlaybackState? =
            config.targets.contains(.mediaKey) ? probePlaybackState(for: .mediaKey) : nil
        queue.async { [self] in
            cachedPlaybackStates.removeAll()
            if let mediaKeyState {
                cachedPlaybackStates[.mediaKey] = mediaKeyState
                log("pre-probe \(DuckTarget.mediaKey.displayName): \(mediaKeyState)")
            }
        }
    }

    func duck() {
        queue.async { [self] in
            log("duck() called, duckedTargets=\(duckedTargets.map { $0.displayName })")

            for target in config.targets {
                guard !duckedTargets.contains(target) else {
                    log("\(target.displayName) already ducked, skipping")
                    continue
                }

                let state = cachedPlaybackStates[target] ?? probePlaybackState(for: target)
                log("\(target.displayName) state: \(state)")

                switch target {
                case .mediaKey:
                    // Browser/system audio (e.g. Firefox YouTube Music or a
                    // YouTube video) can't be volume-ducked without also dragging
                    // down our own speech (same output device) — so we pause it
                    // outright and resume on unduck().
                    //
                    // CRITICAL: only act if audio was ACTUALLY playing before
                    // speech started. The media key is a play/pause *toggle*; if
                    // nothing was playing and we sent it, unduck() would later
                    // toggle again and START playback the user never asked for.
                    // We skip on .paused/.stopped/.unknown for exactly this reason,
                    // and only members of duckedTargets get resumed in unduck().
                    guard state == .playing else {
                        log("\(target.displayName) not playing, skipping (no pause/resume)")
                        continue
                    }
                    log("pausing browser/system media (play/pause key)")
                    sendMediaKey(pause: true)
                    duckedTargets.insert(target)

                case .appleMusic, .spotify:
                    // Volume ramp is harmless on non-playing apps; skip only if paused/stopped
                    guard state == .playing || state == .unknown else {
                        log("\(target.displayName) \(state), skipping volume duck")
                        continue
                    }
                    let vol = getVolume(for: target)
                    originalVolumes[target] = vol
                    log("snapshot \(target.displayName) volume: \(vol)")
                    smoothRampAppVolume(target: target, from: vol, to: config.duckLevel)
                    duckedTargets.insert(target)
                }
            }

            cachedPlaybackStates.removeAll()
            log("duck complete, ducked: \(duckedTargets.map { $0.displayName })")
        }
    }

    func unduck() {
        queue.async { [self] in
            log("unduck() called, duckedTargets=\(duckedTargets.map { $0.displayName })")
            guard !duckedTargets.isEmpty else {
                log("nothing ducked, skipping")
                return
            }

            for target in duckedTargets {
                switch target {
                case .appleMusic, .spotify:
                    if let original = originalVolumes[target] {
                        log("restoring \(target.displayName) to \(original)")
                        smoothRampAppVolume(target: target, from: config.duckLevel, to: original)
                    }
                case .mediaKey:
                    // .mediaKey is only in duckedTargets if we paused it (i.e. it
                    // was playing), so resuming here is always correct.
                    log("resuming browser/system media (play/pause key)")
                    sendMediaKey(pause: false)
                }
            }

            duckedTargets.removeAll()
            originalVolumes.removeAll()
            log("unduck complete")
        }
    }

    func updateConfig(_ config: Config) {
        queue.async { self.config = config }
    }

    /// Diagnostic: PIDs currently producing audio output, paired with their
    /// resolved executable paths. Used by `marduk audio-debug`.
    func audioProducingProcesses() -> [(pid: pid_t, path: String)] {
        queue.sync { [self] in
            audioProducingPIDs().map { ($0, executablePath(for: $0) ?? "<unknown>") }
        }
    }

    // MARK: - Playback State Detection

    private func probePlaybackState(for target: DuckTarget) -> PlaybackState {
        switch target {
        case .appleMusic:
            guard isAppRunning("Music") else { return .stopped }
            guard let raw = runAppleScriptString(
                "tell application \"Music\" to get player state as string"
            ) else { return .unknown }
            return parsePlaybackState(raw)

        case .spotify:
            guard isAppRunning("Spotify") else { return .stopped }
            guard let raw = runAppleScriptString(
                "tell application \"Spotify\" to get player state as string"
            ) else { return .unknown }
            return parsePlaybackState(raw)

        case .mediaKey:
            return isOtherProcessProducingAudio() ? .playing : .paused
        }
    }

    private func parsePlaybackState(_ raw: String) -> PlaybackState {
        let s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("playing") { return .playing }
        if s.contains("paused") { return .paused }
        if s.contains("stopped") { return .stopped }
        return .unknown
    }

    /// Returns true if any process OTHER than this one is actively producing audio output.
    private func isOtherProcessProducingAudio() -> Bool {
        return !audioProducingPIDs().isEmpty
    }

    /// Returns the PIDs (other than ours) currently producing audio output.
    /// Uses macOS 14.4+ Audio HAL process object introspection — this distinguishes
    /// "stream open" (e.g. paused YouTube tab) from "actually producing frames".
    private func audioProducingPIDs() -> [pid_t] {
        let ourPID = getpid()
        var result: [pid_t] = []

        var size: UInt32 = 0
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size
        )
        guard sizeStatus == noErr, size > 0 else {
            log("CoreAudio: failed to get process list size (\(sizeStatus))")
            return result
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var processes = [AudioObjectID](repeating: 0, count: count)
        let listStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size, &processes
        )
        guard listStatus == noErr else {
            log("CoreAudio: failed to get process list (\(listStatus))")
            return result
        }

        for procObj in processes {
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(procObj, &pidAddr, 0, nil, &pidSize, &pid) == noErr,
                  pid != ourPID else { continue }

            var isRunning: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            var runAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(procObj, &runAddr, 0, nil, &runSize, &isRunning) == noErr else { continue }

            if isRunning != 0 {
                // Enhanced/premium voices render in Apple's speech-synthesis
                // service, NOT in our process — so filtering by our own PID is
                // not enough. On back-to-back reads the previous utterance's
                // audio is still draining there, and counting it as "media
                // playing" would send the play/pause toggle for nothing (and
                // START playback on unduck).
                if let path = executablePath(for: pid)?.lowercased(),
                   path.contains("speechsynthesis") || path.contains("com.apple.speech") {
                    log("CoreAudio: PID \(pid) is speech synthesis — ignoring")
                    continue
                }
                log("CoreAudio: PID \(pid) is producing audio output")
                result.append(pid)
            }
        }

        if result.isEmpty {
            log("CoreAudio: no other process producing audio output")
        }
        return result
    }

    // MARK: - Media Key Control

    /// Send a system-wide media play/pause key event.
    /// Posts NX system-defined events via NSEvent+CGEvent — the same event type
    /// that Karabiner's `consumer_key_code: play_or_pause` emits.
    private func sendMediaKey(pause: Bool) {
        // NX_KEYTYPE_PLAY = 16, NX_SUBTYPE_AUX_CONTROL_BUTTONS = 8
        let keyType = 16

        // Key down
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

        // Key up
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

        log("media play/pause event posted")
    }

    // MARK: - App Detection

    private func isAppRunning(_ appName: String) -> Bool {
        let script = "tell application \"System Events\" to (name of processes) contains \"\(appName)\""
        return runAppleScript(script) != nil
    }

    // MARK: - Volume Control

    private func getVolume(for target: DuckTarget) -> Int {
        switch target {
        case .appleMusic:
            return runAppleScript("tell application \"Music\" to get sound volume") ?? 100
        case .spotify:
            return runAppleScript("tell application \"Spotify\" to get sound volume") ?? 100
        case .mediaKey:
            return 100 // media key doesn't have a volume level
        }
    }

    // MARK: - PID -> Executable Path

    /// Resolve a PID to its executable path via libproc. Works for any process,
    /// including Firefox content processes not registered as NSRunningApplication.
    private func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let len = proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN))
        guard len > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - Ramping

    /// Smooth app volume ramp using a single osascript process.
    private func smoothRampAppVolume(target: DuckTarget, from: Int, to: Int) {
        guard let appName = target.appName else { return }
        let steps = config.rampSteps
        let delayPerStep = Double(config.rampDurationMs) / Double(steps) / 1000.0

        log("\(target.displayName) volume: \(from) -> \(to) in \(steps) steps")

        var script = "tell application \"\(appName)\"\n"
        for i in 1...steps {
            let progress = Double(i) / Double(steps)
            let vol = from + Int(Double(to - from) * progress)
            script += "  set sound volume to \(max(0, min(100, vol)))\n"
            if i < steps {
                script += "  delay \(delayPerStep)\n"
            }
        }
        script += "end tell\n"

        runAppleScriptSync(script)
        log("\(target.displayName) ramp complete")
    }

    // MARK: - AppleScript Helpers

    /// Wait for a process to exit, killing it if it exceeds the deadline.
    /// osascript talking to System Events can hang indefinitely; an unbounded
    /// waitUntilExit() would wedge the serial ducker queue forever, making
    /// every later duck/unduck dead until the daemon restarts.
    /// Returns false if the process had to be killed.
    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                log("osascript timed out after \(timeout)s — killing it")
                process.terminate()
                process.waitUntilExit()
                return false
            }
            usleep(20_000)
        }
        return true
    }

    /// Run AppleScript and return integer result. Waits for completion.
    @discardableResult
    private func runAppleScript(_ script: String) -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            guard waitForExit(process, timeout: 3.0) else { return nil }

            if process.terminationStatus != 0 {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                log("osascript error (status \(process.terminationStatus)): \(errStr.trimmingCharacters(in: .whitespacesAndNewlines))")
                return nil
            }

            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                // Handle "true"/"false" from boolean scripts
                if output == "true" { return 1 }
                if output == "false" { return nil }
                return Int(output)
            }
        } catch {
            log("osascript launch error: \(error)")
        }
        return nil
    }

    /// Run AppleScript and return string result. Waits for completion.
    private func runAppleScriptString(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            guard waitForExit(process, timeout: 3.0) else { return nil }

            if process.terminationStatus != 0 {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                log("osascript error (status \(process.terminationStatus)): \(errStr.trimmingCharacters(in: .whitespacesAndNewlines))")
                return nil
            }

            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            log("osascript launch error: \(error)")
        }
        return nil
    }

    /// Run AppleScript synchronously, ignoring result. Waits for completion.
    private func runAppleScriptSync(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        do {
            try process.run()
            // Volume-ramp scripts contain `delay` statements, so allow the
            // ramp duration plus headroom before declaring the process hung.
            let timeout = 3.0 + Double(config.rampDurationMs) / 1000.0
            guard waitForExit(process, timeout: timeout) else { return }

            if process.terminationStatus != 0 {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                log("osascript error: \(errStr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        } catch {
            log("osascript launch error: \(error)")
        }
    }
}
