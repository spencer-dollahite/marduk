import Foundation
import Darwin  // libproc + mach: footprint, threads, fds, other-process rusage

/// One resource reading of the daemon and the speech service it drives.
///
/// WHY THIS EXISTS: the field report is "after a few days, things slow down
/// a LOT — moving the mouse cursor gets very sluggish", and that is exactly
/// the shape of a question the log could not answer. `~/Library/Logs/marduk.log`
/// carries no timestamps of its own (stderr straight to the file; launchd adds
/// nothing), and nothing in it reports memory, so a multi-day session's
/// degradation left no trace: a log covering several days and 1100 utterances
/// showed a perfectly healthy tap and no drift in speech latency, which ruled
/// suspects OUT but could not name the cause. A slow-growing resource leak is
/// unreproducible on demand, so it has to be RECORDED as it happens.
///
/// PRIVACY (the allowlist rule): counts, sizes and times ONLY. The log is
/// designed to be pasted into public GitHub issues (`:log copy`, `:bug`), so
/// nothing here may name a document, a window, a feed, or an app the user
/// happened to be in.
struct HealthSnapshot: Equatable {
    /// Wall-clock stamp, pre-formatted. THE POINT of the line: every other
    /// entry in marduk.log is undated, so "it went bad Tuesday afternoon"
    /// has never been answerable from the log alone.
    var timestamp: String
    /// How long THIS daemon has been up. Self-updates restart the daemon,
    /// so process uptime and "how long since I rebooted" are different
    /// questions and the log should not conflate them.
    var uptime: TimeInterval
    /// Our phys_footprint — the number Activity Monitor calls "Memory".
    var footprintBytes: UInt64
    var threads: Int
    var openFiles: Int
    /// Summed phys_footprint of Apple's speech-synthesis service processes.
    /// Enhanced voices render THERE, not in us (the same fact the ducker
    /// already has to know about), so our own footprint staying flat proves
    /// nothing about the memory Marduk's speech is responsible for.
    /// nil = no such process running, or it could not be read.
    var speechServiceBytes: UInt64?
    var speechServiceCount: Int
    /// Utterances spoken and synthesizers thrown away since boot. The ratio
    /// is the interesting part: rebuilds are one-per-INTERRUPTION and news
    /// mode interrupts on nearly every keystroke, so a session heavy in news
    /// churns hundreds of AVSpeechSynthesizer instances through the speech
    /// service. If that service is what grows, this is the pairing that shows it.
    var utterances: Int
    var synthesizerRebuilds: Int

    /// The log line. Pure — the whole reason the formatting lives apart from
    /// the measuring is that this half can be tested.
    var line: String {
        var parts = [
            "up \(Self.duration(uptime))",
            Self.size(footprintBytes),
            "\(threads) threads",
            "\(openFiles) fds",
        ]
        if let speechServiceBytes {
            let suffix = speechServiceCount > 1 ? " (\(speechServiceCount) procs)" : ""
            parts.append("speech service \(Self.size(speechServiceBytes))\(suffix)")
        } else {
            parts.append("speech service not running")
        }
        parts.append("\(utterances) utterances, \(synthesizerRebuilds) rebuilds")
        return "[health] \(timestamp) — " + parts.joined(separator: ", ")
    }

    /// Bytes as MB/GB. Deliberately coarse: this is read by eye across hours
    /// of log, where "412 MB" and "1.8 GB" are the only distinctions that matter.
    static func size(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return "\(Int(mb.rounded())) MB"
    }

    /// "3d 4h" / "2h 11m" / "14m" / "45s" — two units at most, because the
    /// question this answers is always "roughly how long", never "how long".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }

    /// Local time, seconds precision, sortable. Not ISO-8601 with a zone:
    /// the reader is the user or an issue triager comparing it against
    /// "it got slow around 3pm", and that comparison is in local time.
    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}

/// Logs a `HealthSnapshot` on a slow heartbeat so multi-day degradation
/// leaves evidence behind instead of only being felt.
///
/// Runs OFF the main queue: enumerating every PID to find the speech service
/// costs a `proc_pidpath` per process, which is trivial but is still
/// syscall work with no business on the queue that owns the event tap.
/// Deliberately kept alive in SAFE MODE too (unlike the sentinel, inverter
/// and overlay) — a daemon that has been crash-looping is precisely when a
/// resource reading is worth having, and this subsystem touches nothing:
/// it reads counters and writes one line.
final class HealthMonitor {
    /// Slow on purpose. This is a trend line, not a profiler; an hourly
    /// row is enough to see a leak across days and rare enough that it
    /// never buries the log it shares.
    static let interval: TimeInterval = 3600
    /// One early reading so a session that ends before the first hour
    /// still records where it started — a leak is a DELTA, and a delta
    /// needs a first point.
    static let firstReading: TimeInterval = 60

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.marduk.health")
    private let started = Date()

    /// Supplied by the daemon; read on the health queue, so these must be
    /// cheap and tolerant of a racy read (they are plain Int counters whose
    /// exact value at the instant of sampling does not matter).
    var utteranceCount: () -> Int = { 0 }
    var rebuildCount: () -> Int = { 0 }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.firstReading, repeating: Self.interval)
        t.setEventHandler { [weak self] in self?.emit() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Take a reading and log it. Also called on teardown so the last line
    /// of a session is a reading rather than a guess.
    func emit() {
        let speech = Self.speechServiceFootprint()
        let snapshot = HealthSnapshot(
            timestamp: HealthSnapshot.stamp(Date()),
            uptime: Date().timeIntervalSince(started),
            footprintBytes: Self.footprint(),
            threads: Self.threadCount(),
            openFiles: Self.openFileCount(),
            speechServiceBytes: speech.bytes,
            speechServiceCount: speech.count,
            utterances: utteranceCount(),
            synthesizerRebuilds: rebuildCount())
        fputs(snapshot.line + "\n", stderr)
    }

    // MARK: - Measurement

    /// phys_footprint via TASK_VM_INFO — the same accounting Activity
    /// Monitor shows, which is what a user comparing notes will quote.
    /// resident_size undercounts compressed pages and would make a leak
    /// on a memory-pressured Mac look like it had stopped growing.
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    /// Thread count. NOTE the deallocation: `task_threads` hands back a
    /// send right per thread plus the array itself, and dropping them on
    /// the floor would make this monitor its own slow leak — the exact
    /// failure it was built to detect.
    static func threadCount() -> Int {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS,
              let list else { return 0 }
        for i in 0..<Int(count) {
            mach_port_deallocate(mach_task_self_, list[i])
        }
        vm_deallocate(mach_task_self_,
                      vm_address_t(UInt(bitPattern: UnsafeMutableRawPointer(list))),
                      vm_size_t(Int(count) * MemoryLayout<thread_t>.size))
        return Int(count)
    }

    /// Open file descriptors. A climbing count is the signature of leaked
    /// pipes or sockets — the daemon runs osascript with a `Pipe` on every
    /// duck, and a timed-out script's pipes are never read.
    static func openFileCount() -> Int {
        let pid = getpid()
        let sized = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard sized > 0 else { return 0 }
        // Headroom: fds can open between sizing and listing.
        let capacity = Int(sized) + MemoryLayout<proc_fdinfo>.size * 32
        var buffer = [UInt8](repeating: 0, count: capacity)
        let used = buffer.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32(capacity))
        }
        guard used > 0 else { return 0 }
        return Int(used) / MemoryLayout<proc_fdinfo>.size
    }

    /// Sum the footprint of Apple's speech-synthesis service processes.
    /// Same identification the ducker uses (executable path token), because
    /// there should be exactly one answer to "which process is that" in
    /// this codebase. Any failure degrades to nil — an unreadable service
    /// must never cost us the rest of the line.
    static func speechServiceFootprint() -> (bytes: UInt64?, count: Int) {
        var total: UInt64 = 0
        var found = 0
        for pid in allPIDs() {
            guard let path = executablePath(for: pid)?.lowercased(),
                  path.contains("speechsynthesis") || path.contains("com.apple.speech")
            else { continue }
            if let bytes = footprint(of: pid) {
                total += bytes
                found += 1
            }
        }
        return found > 0 ? (total, found) : (nil, 0)
    }

    private static func allPIDs() -> [pid_t] {
        let sized = proc_listallpids(nil, 0)
        guard sized > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(sized) + 64)
        let bytes = proc_listallpids(&pids,
                                     Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        return Array(pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    private static func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let len = proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN))
        guard len > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Another process's phys_footprint via rusage. Works for processes
    /// owned by the same user without any entitlement; anything else
    /// (a dead PID, a root process) simply returns nil.
    private static func footprint(of pid: pid_t) -> UInt64? {
        var usage = rusage_info_current()
        let rc = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard rc == 0 else { return nil }
        return usage.ri_phys_footprint
    }
}
