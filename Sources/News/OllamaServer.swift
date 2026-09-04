import Foundation

/// Manages a LOCAL `ollama serve` for news triage (user request
/// 2026-08-05: start Ollama when it isn't running, and shut it down
/// after the triage so it stops holding RAM — gemma3 alone is ~3.3 GB
/// on a 16 GB machine).
///
/// Ownership doctrine (the display-inversion rule): "Ollama is running"
/// and "Marduk started Ollama" are different facts. A server the user
/// runs themselves — menu-bar app, brew services, their own terminal —
/// is NEVER touched; only a process this class spawned is terminated,
/// and only when the last triage using it releases it (refcounted, so
/// overlapping triages can't shoot each other's server). Local bases
/// only: a remote `news.ollamaURL` can't be served from this machine.
///
/// Logging is count/metadata only, per the privacy allowlist — the
/// server's stdout/stderr (which can echo prompt fragments) goes to
/// the null device, never the daemon log.
final class OllamaServer {
    static let shared = OllamaServer()

    private let lock = NSLock()
    private var process: Process?
    private var uses = 0

    /// Where the CLI lives — a table, not a code path (brew arm64,
    /// brew intel, the menu-bar app's bundled binary).
    static let binaryPaths = [
        "/opt/homebrew/bin/ollama",
        "/usr/local/bin/ollama",
        "/Applications/Ollama.app/Contents/Resources/ollama",
    ]

    /// Only a loopback base can be started (or stopped) from here.
    static func isLocal(base: String) -> Bool {
        guard let host = URL(string: base)?.host else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// The OLLAMA_HOST value that makes `ollama serve` bind the
    /// configured base — honors a custom local port. Pure, tested.
    static func serveHost(base: String) -> String? {
        guard let url = URL(string: base), let host = url.host else {
            return nil
        }
        return "\(host):\(url.port ?? 11434)"
    }

    enum StartOutcome {
        case alreadyRunning  // answering before we did anything — not ours
        case started         // we spawned it and it came up
        case notLocal        // silent, and the base isn't this machine
        case notInstalled    // silent, and no binary to start
        case failed          // spawned (or tried), never answered
    }

    /// Begin a triage's use of the server: probe, and if silent spawn
    /// `ollama serve` and wait for it to answer. BLOCKING (probe + poll)
    /// — call off-main. Every acquire must be paired with a release(),
    /// whatever the outcome.
    func acquire(base: String) -> StartOutcome {
        lock.lock()
        uses += 1
        lock.unlock()
        if answering(base) { return .alreadyRunning }
        guard Self.isLocal(base: base) else { return .notLocal }

        lock.lock()
        if process?.isRunning != true {
            guard let bin = Self.binaryPaths.first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            }) else {
                lock.unlock()
                return .notInstalled
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["serve"]
            if let host = Self.serveHost(base: base) {
                var env = ProcessInfo.processInfo.environment
                env["OLLAMA_HOST"] = host
                p.environment = env
            }
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch {
                lock.unlock()
                return .failed
            }
            process = p
            fputs("[news] ollama started (pid \(p.processIdentifier))\n",
                  stderr)
        }
        lock.unlock()

        // First boot can be slow on a cold machine — poll up to ~20s.
        for _ in 0..<40 {
            if answering(base) { return .started }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return .failed
    }

    /// End a triage's use. When the LAST user releases and Marduk owns
    /// the server, terminate it (SIGTERM; SIGKILL if it lingers past 5s).
    /// A server that was already running is not ours and stays up.
    func release() {
        lock.lock()
        uses = max(0, uses - 1)
        let p = (uses == 0) ? process : nil
        if uses == 0 { process = nil }
        lock.unlock()
        guard let p, p.isRunning else { return }
        fputs("[news] ollama stopped (triage done)\n", stderr)
        p.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    /// Teardown: kill an owned server regardless of refcount (daemon
    /// exit must never leak an ollama child holding gigabytes of RAM).
    func stop() {
        lock.lock()
        let p = process
        process = nil
        uses = 0
        lock.unlock()
        guard let p, p.isRunning else { return }
        fputs("[news] ollama stopped (teardown)\n", stderr)
        p.terminate()
    }

    /// curl with the body over STDIN — request content (headlines, an
    /// image) never touches a shell argument. Returns nil on any failure.
    /// Shared by the news triage and the image describer.
    static func curl(url: String, body: Data?, timeout: Int) -> Data? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        var arguments = ["-s", "-m", String(timeout), url]
        if body != nil {
            arguments += ["-X", "POST", "-H", "Content-Type: application/json",
                          "--data-binary", "@-"]
        }
        task.arguments = arguments
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        if body != nil { task.standardInput = stdin }
        do { try task.run() } catch { return nil }
        if let body {
            stdin.fileHandleForWriting.write(body)
            stdin.fileHandleForWriting.closeFile()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    /// GET /api/tags as a liveness probe — no body, no user content.
    func answering(_ base: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = ["-s", "-m", "2", "-o", "/dev/null", "\(base)/api/tags"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}
