import Foundation
import AppKit           // NSWorkspace sleep/wake notifications
import CoreGraphics     // CGGetEventTapList — the system's own tap latency figures
import Darwin           // libproc + mach: footprint, threads, fds, other-process rusage

/// One resource reading of the daemon, the speech service it drives, and
/// the parts of the SYSTEM that make a pointer sluggish.
///
/// WHY THIS EXISTS: the field report is "after a few days things slow down
/// a LOT — moving the mouse cursor gets very sluggish", and that is exactly
/// the shape of a question the log could not answer. `~/Library/Logs/marduk.log`
/// carries no timestamps of its own (stderr straight to the file; launchd adds
/// nothing), and nothing in it reported memory, so a multi-day session's
/// degradation left no trace: a log covering several days and 1100 utterances
/// showed a perfectly healthy tap and no drift in speech latency, which ruled
/// suspects OUT but could not name the cause. A slow-growing resource leak is
/// unreproducible on demand, so it has to be RECORDED as it happens.
///
/// SECOND ROUND (2026-09-04): the first version of this line answered its
/// own question — three days of hourly readings showed Marduk's process
/// FLAT (26 MB, 15 threads, 5 fds) while the machine got slow, and the
/// slowdown arrived overnight, across a lock-and-sleep, with Marduk idle.
/// So the process is not where the answer lives, and the reading grew to
/// cover the places it can: the pointer's own event path (every event tap
/// in the session, with the latencies macOS itself measures for them),
/// WindowServer (what zoom and the cursor are drawn by), system memory
/// pressure (a Mac that spent the night compressing and swapping is slow
/// the moment it wakes), and the flags Marduk sets on OTHER processes
/// (`AXNudge`) — plus a reading at sleep, at wake and at unlock, so the
/// before/after of the exact moment the user feels it is on record.
///
/// PRIVACY (the allowlist rule): counts, sizes and times ONLY. The log is
/// designed to be pasted into public GitHub issues (`:log copy`, `:bug`), so
/// nothing here may name a document, a window, a feed, or an app the user
/// happened to be in. The tap and largest-process lines name PROCESSES by
/// executable basename — software identity, the same standing as the
/// bundle IDs the `[display]` lines already print on every activation —
/// never a window title, document or URL.
struct HealthSnapshot: Equatable {
    /// What produced the reading. An enum, not text, so the reflective
    /// privacy test keeps its "no strings but the timestamp" rule.
    enum Trigger: String {
        case scheduled, sleep, wake, unlocked, shutdown
    }

    /// Wall-clock stamp, pre-formatted. THE POINT of the line: every other
    /// entry in marduk.log is undated, so "it went bad Tuesday afternoon"
    /// has never been answerable from the log alone.
    var timestamp: String
    var trigger: Trigger = .scheduled
    /// How long THIS daemon has been up. Self-updates restart the daemon,
    /// so process uptime and "how long since I rebooted" are different
    /// questions and the log should not conflate them.
    var uptime: TimeInterval
    /// Our phys_footprint — the number Activity Monitor calls "Memory".
    var footprintBytes: UInt64
    var threads: Int
    var openFiles: Int
    /// Our own CPU over the interval since the previous reading, percent
    /// of one core. nil on the first reading (a rate needs two points).
    var cpuPercent: Double?
    /// Worst main-queue lag the latency sentinel saw since the previous
    /// reading. The tap dispatches every key to main, so a main thread
    /// that stalls for two seconds delays every key by two seconds
    /// without ever tripping the 4s fail-open.
    var mainLagMaxSeconds: TimeInterval = 0
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

    // MARK: The pointer's event path

    /// Every event tap in the login session, ours included. A tap is a
    /// process the window server must consult before an event is
    /// delivered; a slow one slows whatever it listens to. 0 = the list
    /// could not be read.
    var eventTaps: Int = 0
    /// macOS's own running measurement of OUR tap's callback (microseconds).
    /// nil = our tap was not in the list (no tap, or the list failed).
    var ownTapAvgUsec: Double?
    var ownTapMaxUsec: Double?
    /// Taps owned by OTHER processes that listen to pointer motion (mouse
    /// moved / dragged). Marduk's tap never does — so if the pointer is
    /// slow through a tap, one of these is the tap.
    var foreignPointerTaps: Int = 0

    // MARK: The system

    /// WindowServer draws the cursor and the zoomed framebuffer; when it is
    /// drowning, the pointer is what the user feels. nil = unreadable.
    var windowServerBytes: UInt64?
    var windowServerCPUPercent: Double?
    /// System memory: used (app + wired + compressed) of total, how much
    /// is compressed, how much is swapped. A Mac that spent a night
    /// compressing is slow on wake until it pages everything back in.
    var systemUsedBytes: UInt64 = 0
    var systemTotalBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0
    var swapUsedBytes: UInt64 = 0
    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warn, 4 critical,
    /// 0 unknown.
    var pressureLevel: Int = 0

    // MARK: What we hold in OTHER processes

    /// Accessibility flags currently set on other apps by us (`AXNudge`).
    /// Between reads this must be 0; a climbing number is a restore that
    /// stopped firing.
    var axFlagsHeld: Int = 0
    /// AX observer registrations made / taken back since start (the dialog
    /// sentinel re-registers on every app switch). They must stay equal:
    /// a registration is state in the OBSERVED process, and a browser that
    /// runs for days used to collect one dead registration per switch.
    var axRegistrations: Int = 0
    var axDeregistrations: Int = 0

    /// The log line. Pure — the whole reason the formatting lives apart from
    /// the measuring is that this half can be tested.
    var line: String {
        var parts = [
            "up \(Self.duration(uptime))",
            Self.size(footprintBytes),
            "\(threads) threads",
            "\(openFiles) fds",
        ]
        if let cpuPercent {
            parts.append("cpu \(Self.percent(cpuPercent))")
        }
        parts.append("main lag \(Self.seconds(mainLagMaxSeconds))")
        if let speechServiceBytes {
            let suffix = speechServiceCount > 1 ? " (\(speechServiceCount) procs)" : ""
            parts.append("speech service \(Self.size(speechServiceBytes))\(suffix)")
        } else {
            parts.append("speech service not running")
        }
        parts.append("\(utterances) utterances, \(synthesizerRebuilds) rebuilds")
        let label = trigger == .scheduled ? "" : " (\(trigger.rawValue))"
        return "[health] \(timestamp)\(label) — " + parts.joined(separator: ", ")
    }

    /// The second line: the pointer's path and the system around it.
    var systemLine: String {
        var parts: [String] = []
        if eventTaps > 0 {
            var tap = "taps \(eventTaps)"
            if let ownTapAvgUsec, let ownTapMaxUsec {
                tap += " (ours avg \(Self.micros(ownTapAvgUsec)) max \(Self.micros(ownTapMaxUsec))"
                tap += foreignPointerTaps > 0
                    ? ", \(foreignPointerTaps) foreign pointer tap\(foreignPointerTaps == 1 ? "" : "s"))"
                    : ", no foreign pointer taps)"
            } else {
                tap += " (ours not found)"
            }
            parts.append(tap)
        } else {
            parts.append("taps unreadable")
        }
        if let windowServerBytes {
            var ws = "WindowServer \(Self.size(windowServerBytes))"
            if let windowServerCPUPercent {
                ws += " \(Self.percent(windowServerCPUPercent)) cpu"
            }
            parts.append(ws)
        } else {
            parts.append("WindowServer unreadable")
        }
        if systemTotalBytes > 0 {
            parts.append("memory \(Self.size(systemUsedBytes)) of "
                         + "\(Self.size(systemTotalBytes)) used")
            parts.append("\(Self.size(compressedBytes)) compressed")
            parts.append("\(Self.size(swapUsedBytes)) swap")
            parts.append("pressure \(Self.pressureName(pressureLevel))")
        }
        parts.append("ax flags held \(axFlagsHeld)")
        parts.append("ax observers \(axRegistrations)/\(axDeregistrations)")
        return "[health] system: " + parts.joined(separator: ", ")
    }

    static func pressureName(_ level: Int) -> String {
        switch level {
        case 1: return "normal"
        case 2: return "warn"
        case 4: return "critical"
        default: return "unknown"
        }
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

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", max(0, value))
    }

    static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.2fs", max(0, value))
    }

    /// Microseconds as "41µs" / "1.2ms" — a tap callback is judged against
    /// the ~8ms an event has before the pointer visibly stutters.
    static func micros(_ usec: Double) -> String {
        if usec >= 1000 { return String(format: "%.1fms", usec / 1000) }
        return "\(Int(usec.rounded()))µs"
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

/// The per-tap detail behind `HealthSnapshot.eventTaps`: who taps what, and
/// how slowly. Pure — built from `CGGetEventTapList` by the monitor, rendered
/// here so the rendering is testable.
struct TapReport: Equatable {
    struct Entry: Equatable {
        /// Executable basename of the tapping process (software identity).
        var owner: String
        var isOurs: Bool
        var listensToKeys: Bool
        var listensToPointer: Bool
        var enabled: Bool
        var avgUsec: Double
        var maxUsec: Double
    }
    var entries: [Entry]

    /// Pointer-motion events: moved and dragged. A tap listening to these
    /// is in the path of every cursor movement.
    static let pointerMask: CGEventMask =
        (1 << CGEventType.mouseMoved.rawValue)
        | (1 << CGEventType.leftMouseDragged.rawValue)
        | (1 << CGEventType.rightMouseDragged.rawValue)
        | (1 << CGEventType.otherMouseDragged.rawValue)
    static let keyMask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

    static func entry(owner: String, isOurs: Bool, mask: CGEventMask,
                      enabled: Bool, avgUsec: Double, maxUsec: Double) -> Entry {
        Entry(owner: owner, isOurs: isOurs,
              listensToKeys: mask & keyMask != 0,
              listensToPointer: mask & pointerMask != 0,
              enabled: enabled, avgUsec: avgUsec, maxUsec: maxUsec)
    }

    /// One line, slowest first, so the tap worth looking at is the first
    /// thing on it. Disabled taps are marked: a tap macOS switched off for
    /// being slow is a finding in itself.
    var line: String {
        guard !entries.isEmpty else { return "[health] taps: none listed" }
        let ordered = entries.sorted { $0.avgUsec > $1.avgUsec }
        let rendered = ordered.map { e -> String in
            var what: [String] = []
            if e.listensToKeys { what.append("keys") }
            if e.listensToPointer { what.append("pointer") }
            if what.isEmpty { what.append("other") }
            var s = "\(e.owner)\(e.isOurs ? " (us)" : "") \(what.joined(separator: "+"))"
            s += " avg \(HealthSnapshot.micros(e.avgUsec)) max \(HealthSnapshot.micros(e.maxUsec))"
            if !e.enabled { s += " DISABLED" }
            return s
        }
        return "[health] taps: " + rendered.joined(separator: "; ")
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
/// it reads counters and writes a line.
final class HealthMonitor {
    /// Slow on purpose. This is a trend line, not a profiler; an hourly
    /// row is enough to see a leak across days and rare enough that it
    /// never buries the log it shares.
    static let interval: TimeInterval = 3600
    /// One early reading so a session that ends before the first hour
    /// still records where it started — a leak is a DELTA, and a delta
    /// needs a first point.
    static let firstReading: TimeInterval = 60
    /// How many of the biggest processes the `largest:` line names.
    static let largestCount = 3

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.marduk.health")
    private let started = Date()
    private var powerObservers: [NSObjectProtocol] = []
    private var unlockObserver: NSObjectProtocol?

    /// The previous reading's CPU clocks, for the rates. Health-queue only.
    private var lastOwnCPU: (seconds: Double, at: Date)?
    private var lastWindowServerCPU: (seconds: Double, at: Date)?

    /// Supplied by the daemon; read on the health queue, so these must be
    /// cheap and tolerant of a racy read (they are plain Int counters whose
    /// exact value at the instant of sampling does not matter).
    var utteranceCount: () -> Int = { 0 }
    var rebuildCount: () -> Int = { 0 }
    var mainLagMax: () -> TimeInterval = { 0 }
    var axFlagsHeld: () -> Int = { 0 }
    var axObserverCounts: () -> (registered: Int, deregistered: Int) = { (0, 0) }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.firstReading, repeating: Self.interval)
        t.setEventHandler { [weak self] in self?.emit() }
        t.resume()
        timer = t

        // The moments the user actually FEELS a slow machine: waking it,
        // and logging back in. A reading at sleep gives the before, one at
        // wake the after, one at unlock the moment of the complaint —
        // three points that a purely hourly beat lands on by luck.
        let center = NSWorkspace.shared.notificationCenter
        powerObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification,
                               object: nil, queue: nil) { [weak self] _ in
                self?.emit(trigger: .sleep)
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification,
                               object: nil, queue: nil) { [weak self] _ in
                self?.emit(trigger: .wake)
            },
        ]
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.emit(trigger: .unlocked)
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        for observer in powerObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        powerObservers = []
        if let unlockObserver {
            DistributedNotificationCenter.default().removeObserver(unlockObserver)
            self.unlockObserver = nil
        }
    }

    /// Take a reading and log it. Also called on teardown so the last line
    /// of a session is a reading rather than a guess. Trigger-driven calls
    /// arrive on arbitrary queues and hop to the health queue; the
    /// shutdown reading runs inline because the process is about to exit.
    func emit(trigger: HealthSnapshot.Trigger = .scheduled) {
        if trigger == .shutdown {
            queue.sync { self.measureAndLog(trigger: trigger) }
        } else if trigger == .scheduled {
            measureAndLog(trigger: trigger)  // already on the health queue
        } else {
            queue.async { self.measureAndLog(trigger: trigger) }
        }
    }

    private func measureAndLog(trigger: HealthSnapshot.Trigger) {
        let now = Date()
        let speech = Self.speechServiceFootprint()
        let taps = Self.eventTapList()
        let ownTap = taps.first { $0.tappingProcess == getpid() }
        let foreignPointer = taps.filter {
            $0.tappingProcess != getpid() && $0.eventsOfInterest & TapReport.pointerMask != 0
        }.count
        let windowServer = Self.windowServerUsage()
        let memory = Self.systemMemory()
        let observers = axObserverCounts()

        let ownCPU = Self.ownCPUSeconds()
        let cpuPercent = Self.rate(now: ownCPU, at: now, previous: lastOwnCPU)
        lastOwnCPU = (ownCPU, now)
        var wsPercent: Double?
        if let windowServer {
            wsPercent = Self.rate(now: windowServer.cpuSeconds, at: now,
                                  previous: lastWindowServerCPU)
            lastWindowServerCPU = (windowServer.cpuSeconds, now)
        }

        let snapshot = HealthSnapshot(
            timestamp: HealthSnapshot.stamp(now),
            trigger: trigger,
            uptime: now.timeIntervalSince(started),
            footprintBytes: Self.footprint(),
            threads: Self.threadCount(),
            openFiles: Self.openFileCount(),
            cpuPercent: cpuPercent,
            mainLagMaxSeconds: mainLagMax(),
            speechServiceBytes: speech.bytes,
            speechServiceCount: speech.count,
            utterances: utteranceCount(),
            synthesizerRebuilds: rebuildCount(),
            eventTaps: taps.count,
            ownTapAvgUsec: ownTap.map { Double($0.avgUsecLatency) },
            ownTapMaxUsec: ownTap.map { Double($0.maxUsecLatency) },
            foreignPointerTaps: foreignPointer,
            windowServerBytes: windowServer?.bytes,
            windowServerCPUPercent: wsPercent,
            systemUsedBytes: memory.used,
            systemTotalBytes: memory.total,
            compressedBytes: memory.compressed,
            swapUsedBytes: memory.swapUsed,
            pressureLevel: memory.pressure,
            axFlagsHeld: axFlagsHeld(),
            axRegistrations: observers.registered,
            axDeregistrations: observers.deregistered)
        fputs(snapshot.line + "\n", stderr)
        fputs(snapshot.systemLine + "\n", stderr)
        fputs(Self.tapReport(taps).line + "\n", stderr)
        fputs(Self.largestLine() + "\n", stderr)
    }

    /// CPU seconds → percent of one core over the interval since `previous`.
    /// nil without a previous point, or if the clock went backwards.
    static func rate(now: Double, at: Date,
                     previous: (seconds: Double, at: Date)?) -> Double? {
        guard let previous else { return nil }
        let wall = at.timeIntervalSince(previous.at)
        guard wall > 1 else { return nil }
        let cpu = now - previous.seconds
        guard cpu >= 0 else { return nil }
        return cpu / wall * 100
    }

    // MARK: - Measurement: this process

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

    /// Our own user+system CPU time, seconds. getrusage is unambiguous
    /// (timevals), unlike the mach-unit clocks of other processes.
    static func ownCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + system
    }

    // MARK: - Measurement: the event path

    /// Every event tap in the session, as macOS reports them — including
    /// the min/avg/max callback latency IT measures for each. This is the
    /// authoritative answer to "is a tap slowing the pointer", and it names
    /// the process if one is.
    static func eventTapList() -> [CGEventTapInformation] {
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: 64)
        var count: UInt32 = 0
        let err = CGGetEventTapList(UInt32(taps.count), &taps, &count)
        guard err == .success else { return [] }
        return Array(taps.prefix(Int(count)))
    }

    static func tapReport(_ taps: [CGEventTapInformation]) -> TapReport {
        TapReport(entries: taps.map { tap in
            let owner = executablePath(for: tap.tappingProcess)
                .map { ($0 as NSString).lastPathComponent } ?? "pid \(tap.tappingProcess)"
            return TapReport.entry(owner: owner, isOurs: tap.tappingProcess == getpid(),
                                   mask: tap.eventsOfInterest, enabled: tap.enabled,
                                   avgUsec: Double(tap.avgUsecLatency),
                                   maxUsec: Double(tap.maxUsecLatency))
        })
    }

    // MARK: - Measurement: other processes

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

    /// WindowServer's footprint and CPU clock. It runs as another user, so
    /// rusage may be refused; the task-info fallback is what `ps` uses and
    /// is readable across users. nil if both refuse — reported as such,
    /// never as 0.
    static func windowServerUsage() -> (bytes: UInt64, cpuSeconds: Double)? {
        guard let pid = allPIDs().first(where: {
            (executablePath(for: $0) as NSString?)?.lastPathComponent == "WindowServer"
        }) else { return nil }
        return processUsage(of: pid)
    }

    static func processUsage(of pid: pid_t) -> (bytes: UInt64, cpuSeconds: Double)? {
        var usage = rusage_info_current()
        let rc = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        if rc == 0 {
            return (usage.ri_phys_footprint,
                    machSeconds(usage.ri_user_time &+ usage.ri_system_time))
        }
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let got = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, size)
        }
        guard got == size else { return nil }
        return (info.pti_resident_size,
                machSeconds(info.pti_total_user &+ info.pti_total_system))
    }

    /// rusage_info and proc_taskinfo clocks are in mach absolute units —
    /// nanoseconds on Intel, 1/24 µs on Apple silicon — so convert, or a
    /// CPU percentage is off by 41× on one of the two.
    static func machSeconds(_ ticks: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else {
            return Double(ticks) / 1e9
        }
        return Double(ticks) * Double(info.numer) / Double(info.denom) / 1e9
    }

    /// The biggest processes by footprint, as a line. Named by executable
    /// basename (software identity, like the bundle IDs the display log
    /// already prints) — never by window or document.
    static func largestLine() -> String {
        var rows: [(name: String, bytes: UInt64)] = []
        for pid in allPIDs() {
            guard let bytes = footprint(of: pid), bytes > 0,
                  let path = executablePath(for: pid) else { continue }
            rows.append(((path as NSString).lastPathComponent, bytes))
        }
        let top = rows.sorted { $0.bytes > $1.bytes }.prefix(largestCount)
        guard !top.isEmpty else { return "[health] largest: unreadable" }
        return "[health] largest: " + top.map {
            "\($0.name) \(HealthSnapshot.size($0.bytes))"
        }.joined(separator: ", ")
    }

    // MARK: - Measurement: the system

    /// Used/total/compressed/swap and the kernel's own pressure verdict.
    /// "Used" follows Activity Monitor: app memory (internal minus
    /// purgeable) + wired + compressed.
    static func systemMemory()
        -> (used: UInt64, total: UInt64, compressed: UInt64, swapUsed: UInt64, pressure: Int) {
        let total = ProcessInfo.processInfo.physicalMemory
        let page = UInt64(vm_kernel_page_size)
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        mach_port_deallocate(mach_task_self_, host)  // a send right, not a leak
        var used: UInt64 = 0
        var compressed: UInt64 = 0
        if kr == KERN_SUCCESS {
            compressed = UInt64(stats.compressor_page_count) * page
            let app = UInt64(max(0, Int64(stats.internal_page_count)
                                  - Int64(stats.purgeable_count))) * page
            used = app + UInt64(stats.wire_count) * page + compressed
        }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapUsed = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
            ? swap.xsu_used : 0
        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        let pressure = sysctlbyname("kern.memorystatus_vm_pressure_level",
                                    &level, &levelSize, nil, 0) == 0 ? Int(level) : 0
        return (used, total, compressed, swapUsed, pressure)
    }

    // MARK: - libproc helpers

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
