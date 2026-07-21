import Foundation
import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Display management for bright apps in a dark-mode workflow. Two tools:
///
/// 1. FULL-DISPLAY INVERSION for apps that are hopelessly light (Pages,
///    Packet Tracer): inverts the moment a listed app is seen in front;
///    un-inverts ONLY via the 2s heartbeat poll, after 6 continuous
///    seconds of the holder being gone. Events may invert; they may NEVER
///    revert — an entire evening of field logs proved every event-shaped
///    signal (activation, dwell, settle, window stack, leases) eventually
///    lies, in both directions, for both Qt and native apps.
/// 2. PREVIEW DARK PDFs: Preview's per-window dark-appearance menu item
///    ("Use Dark Appearance for PDF" on macOS 26) — pressed directly via
///    the AX menu bar (no shortcut needed) whenever Preview comes front or
///    opens a new window, checkmark consulted first so an already-dark
///    window is never toggled back to light. `pdfdark auto` (DEFAULT)
///    follows the system appearance — dark theme users get dark PDFs with
///    zero setup, light theme leaves Preview alone — reacting live to
///    theme flips; on/off override. English menu titles only (Marduk-wide
///    limitation).
///
/// 3. AUTO-DETECTION (`:config autoinvert`, needs the Screen Recording
///    permission — requested on enable): apps NOT in the list are measured
///    on activation — a 64px ScreenCaptureKit screenshot of the frontmost
///    window, mean channel brightness against `display.autoInvertThreshold`
///    (percent, default 70) — and inverted or reverted accordingly. Listed
///    apps skip the measurement and invert instantly; Preview is skipped
///    when pdfdark handles it. macOS periodically re-confirms screen
///    capture grants — the price of the magic, disclosed in the tip.
///
/// Everything defaults OFF/empty — visual surprises make terrible first
/// impressions — and applies live via `:config invert` / `:config pdfdark`
/// / `:config autoinvert`.
// @unchecked Sendable: the codebase's standard workaround — the brightness
// Task hops off-main; mutable state it touches is a threshold read and a
// log-once flag, and all decisions re-enter main before acting.
final class DisplayInverter: @unchecked Sendable {
    enum PDFDarkStyle: String {
        case auto, on, off
    }

    var invertApps: Set<String>
    var invertEnabled = true
    /// auto (default) follows the system appearance: dark theme → dark
    /// PDFs, light theme → untouched. on/off are explicit overrides.
    var pdfDarkStyle: PDFDarkStyle = .auto

    var previewDarkActive: Bool {
        switch pdfDarkStyle {
        case .on: return true
        case .off: return false
        case .auto: return Self.systemIsDark()
        }
    }

    static func systemIsDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }
    var autoInvert = false
    /// Mean-brightness threshold, 0…1 (config carries percent).
    var autoInvertThreshold = 0.70
    private var captureFailureLogged = false

    private var isInverted = false
    private var observer: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?
    private var previewObserver: AXObserver?
    private var previewObserverPID: pid_t = -1

    // THE MECHANISM, settled by a night of field forensics: fire the
    // system Invert Colors keyboard shortcut through System Events
    // (osascript) — the sanctioned symbolic-hotkey path, hardware-verified
    // to STICK. Raw CGEvent chords are ignored by the hotkey handler, and
    // the private UAWhiteOnBlackSetEnabled SELF-FLICKERS on macOS 26
    // (filter flashes on, universalaccessd overrides it back off, pref
    // left stranded at 1 — proven by the one-shot latch experiment: one
    // call, closed latch, still flickered). Do not resurrect either.
    // The user's actual binding is auto-discovered from
    // com.apple.symbolichotkeys entry 21 (fallback Shift+Cmd+F13).
    static func invertShortcut() -> (keyCode: Int, modifiers: [String], enabled: Bool)? {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        guard let hotkeys = CFPreferencesCopyAppValue(
                  "AppleSymbolicHotKeys" as CFString, domain) as? [String: Any],
              let entry = hotkeys["21"] as? [String: Any] else { return nil }
        let enabled = (entry["enabled"] as? NSNumber)?.boolValue ?? true
        guard let value = entry["value"] as? [String: Any],
              let params = value["parameters"] as? [NSNumber], params.count >= 3 else {
            return nil
        }
        let mask = params[2].intValue
        var mods: [String] = []
        if mask & (1 << 17) != 0 { mods.append("shift") }
        if mask & (1 << 18) != 0 { mods.append("control") }
        if mask & (1 << 19) != 0 { mods.append("option") }
        if mask & (1 << 20) != 0 { mods.append("command") }
        return (params[1].intValue, mods, enabled)
    }

    private let scriptQueue = DispatchQueue(label: "com.marduk.display.invert",
                                            qos: .userInitiated)

    static let previewBundle = "com.apple.Preview"

    /// Always inversion candidates, matched by bundle-ID PREFIX — Cisco
    /// Packet Tracer versions its bundle ID per release
    /// (com.netacad.PacketTracer9.0.0…). User-ratified hardcoding after
    /// auto-detection lost the war against PT's activation/window churn.
    static let builtInInvertPrefixes = [
        "com.netacad.PacketTracer",
        "com.apple.iWork.Pages",
    ]

    private func isListed(_ bundleID: String) -> Bool {
        invertApps.contains(bundleID)
            || Self.builtInInvertPrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// Apps whose activation events LIE (ghost blips while the user never
    /// left) — reverts from these holders need the multi-sample envelope.
    /// Well-behaved holders (Pages) revert instantly on the departure
    /// event: the fog-of-war era blamed events for flicker that the
    /// post-mortem pinned on the self-flickering private setter.
    private static let flappyPrefixes = ["com.netacad.PacketTracer"]

    private static func isFlappy(_ bundleID: String) -> Bool {
        flappyPrefixes.contains { bundleID.hasPrefix($0) }
    }

    init(invertApps: [String]) {
        self.invertApps = Set(invertApps)
    }

    func start() {
        // The user (or a crash) may have left the display inverted —
        // bookkeeping starts from the system's actual state
        isInverted = Self.displayIsInverted()

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            // FAST PATH: listed apps invert on the raw event — eager
            // inversion is always safe (reverting is the heartbeat's, and
            // an extra invert of a listed app is simply correct). Preview
            // dark-PDF likewise. Only auto-measurement rides the dwell.
            if self.isListed(bundleID) {
                self.lastHolderSeen = Date()
                self.fastConfirmGeneration += 1  // holder is back — abort any burst
                // Post-revert guard: our own revert kicks Qt rebuilds whose
                // activation blips would instantly re-darken the next app;
                // a genuine return still re-inverts via the dwell path
                if Date().timeIntervalSince(self.lastRevertAt) > 2.5 {
                    self.ensureInverted(true, holder: bundleID, reason: bundleID)
                }
            } else if bundleID == Self.previewBundle, self.previewDarkActive {
                self.applyPreviewDarkMode(pid: app.processIdentifier)
                self.observePreviewWindows(pid: app.processIdentifier)
            } else if self.isInverted {
                if let holder = self.invertHolder, !Self.isFlappy(holder) {
                    // Trustworthy holder: the departure event IS the truth —
                    // revert now (click, Karabiner jump, Cmd+Tab alike)
                    self.ensureInverted(false, holder: nil,
                                        reason: "left \(holder) for \(bundleID)")
                } else {
                    // Flappy holder (PT): the event only STARTS the fast
                    // envelope — its ghost blips abort it by resurfacing
                    self.beginFastRevertConfirm()
                }
            }
            self.scheduleActivation(bundleID, pid: app.processIdentifier)
        }

        // Check current foreground app immediately (handles daemon restart)
        if let app = NSWorkspace.shared.frontmostApplication,
           let bundleID = app.bundleIdentifier {
            scheduleActivation(bundleID, pid: app.processIdentifier)
        }

        // A theme flip while Preview is front should dark its PDFs at
        // that moment (auto style). Going light never un-darks windows —
        // reopening them is cheap, toggling them all is presumptuous.
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyPreviewDarkModeIfFront()
        }

        // The heartbeat: the ONLY authority allowed to revert. 2s of
        // NSWorkspace reads is negligible; its judgments are about
        // envelopes (6s of absence), never instants.
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval,
                                         repeats: true) { [weak self] _ in
            self?.poll()
        }

        fputs("[display] tracking started (\(invertApps.count) listed + "
            + "\(Self.builtInInvertPrefixes.count) built-in, PDF dark "
            + "\(pdfDarkStyle.rawValue), hotkey-fast)\n", stderr)
    }

    func stop() {
        if let observer = observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        if let observer = themeObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            themeObserver = nil
        }
        teardownPreviewObserver()
        pollTimer?.invalidate()
        pollTimer = nil
        // Revert inversion if active
        if isInverted {
            lastToggleAt = Date()
            applyInversion(false)
            isInverted = false
            fputs("[display] Reverted inversion on stop\n", stderr)
        }
    }

    /// Live `:config invert off` mid-invert must hand the display back.
    func revertIfInverted() {
        if isInverted {
            lastToggleAt = Date()
            applyInversion(false)
            isInverted = false
            fputs("[display] Reverted inversion (invert off)\n", stderr)
        }
    }

    /// Force TCC registration: a capture attempt makes Marduk appear in
    /// the Screen Recording privacy pane even when macOS shows no dialog
    /// (modern macOS often registers silently instead of prompting).
    func primeCapturePermission() {
        Task {
            _ = try? await SCShareableContent
                .excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
    }

    /// Live `:config pdfdark` change (or a theme flip) with Preview
    /// already front applies now.
    func applyPreviewDarkModeIfFront() {
        guard previewDarkActive,
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == Self.previewBundle else { return }
        applyPreviewDarkMode(pid: app.processIdentifier)
        observePreviewWindows(pid: app.processIdentifier)
    }

    // Qt apps (Packet Tracer) bounce macOS activation to the NEXT app for
    // a few hundred ms every time a dialog churns — field log: PT → Terminal
    // → PT phantom cycles inverting and reverting the whole display while
    // the user never left PT. Nothing acts until an app HOLDS the front for
    // the dwell; a newer activation cancels the pending one.
    private var pendingActivation: DispatchWorkItem?
    private static let activationDwell: TimeInterval = 0.4

    /// The app that owns the topmost normal-layer window — what the user's
    /// EYES consider front. NSWorkspace activation turned out to be
    /// politics: Packet Tracer flaps it chronically (dialog churn), and
    /// every activation-based scheme strobed the display while PT's window
    /// never left the top of the screen. Window z-order is ground truth.
    /// Basic window info needs no Screen Recording (names are redacted;
    /// we read only layer, owner, and bounds).
    static func visuallyFrontmostApp() -> (bundleID: String, pid: pid_t)? {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for window in info {  // front-to-back
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  pid != getpid(),
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double,
                  let height = bounds["Height"] as? Double,
                  width > 200, height > 150,
                  let app = NSRunningApplication(processIdentifier: pid),
                  let bundle = app.bundleIdentifier else { continue }
            return (bundle, pid)
        }
        return nil
    }

    // OUR OWN inversion changes the display configuration, which makes Qt
    // apps tear down and rebuild windows — resigning activation for over a
    // second and handing the front to the next app. Acting on that echo
    // reverts, which kicks Qt again: a self-sustaining strobe (field log,
    // twice — the dwell alone slowed it without breaking it). After every
    // toggle, activations are IGNORED for a settle window; at its close the
    // then-current frontmost is evaluated once, so a real switch made
    // during the window is still honored, just late.
    private var settleUntil = Date.distantPast
    private static let settleWindow: TimeInterval = 0.6

    private func beginSettleWindow() {
        settleUntil = Date().addingTimeInterval(Self.settleWindow)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleWindow + 0.1) {
            [weak self] in
            guard let self,
                  let app = NSWorkspace.shared.frontmostApplication,
                  let bundleID = app.bundleIdentifier else { return }
            // FAST PATH: listed apps invert on the raw event — eager
            // inversion is always safe (reverting is the heartbeat's, and
            // an extra invert of a listed app is simply correct). Preview
            // dark-PDF likewise. Only auto-measurement rides the dwell.
            if self.isListed(bundleID) {
                self.lastHolderSeen = Date()
                self.fastConfirmGeneration += 1  // holder is back — abort any burst
                // Post-revert guard: our own revert kicks Qt rebuilds whose
                // activation blips would instantly re-darken the next app;
                // a genuine return still re-inverts via the dwell path
                if Date().timeIntervalSince(self.lastRevertAt) > 2.5 {
                    self.ensureInverted(true, holder: bundleID, reason: bundleID)
                }
            } else if bundleID == Self.previewBundle, self.previewDarkActive {
                self.applyPreviewDarkMode(pid: app.processIdentifier)
                self.observePreviewWindows(pid: app.processIdentifier)
            } else if self.isInverted {
                if let holder = self.invertHolder, !Self.isFlappy(holder) {
                    // Trustworthy holder: the departure event IS the truth —
                    // revert now (click, Karabiner jump, Cmd+Tab alike)
                    self.ensureInverted(false, holder: nil,
                                        reason: "left \(holder) for \(bundleID)")
                } else {
                    // Flappy holder (PT): the event only STARTS the fast
                    // envelope — its ghost blips abort it by resurfacing
                    self.beginFastRevertConfirm()
                }
            }
            self.scheduleActivation(bundleID, pid: app.processIdentifier)
        }
    }

    private func scheduleActivation(_ bundleID: String, pid: pid_t) {
        guard Date() >= settleUntil else { return }
        pendingActivation?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let front = self.resolveFront() else { return }
            self.handleAppActivated(front.bundleID, pid: front.pid)
        }
        pendingActivation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.activationDwell,
                                      execute: work)
    }

    /// Who's front? Neither signal alone survived the field: activation
    /// flaps (PT churn), and the window stack can miss PT entirely (Qt
    /// windows aren't guaranteed layer-0 citizens — the build that trusted
    /// it left PT uninverted). Consult BOTH, biased toward any LISTED app:
    /// inverting eagerly is safe because reverts need two confirmed
    /// strikes. Disagreements are logged — bundle IDs only.
    func resolveFront() -> (bundleID: String, pid: pid_t)? {
        let activationApp = NSWorkspace.shared.frontmostApplication
        let activation: (bundleID: String, pid: pid_t)? = activationApp
            .flatMap { app in app.bundleIdentifier.map { ($0, app.processIdentifier) } }
        let visual = Self.visuallyFrontmostApp()
        if let a = activation, let v = visual, a.bundleID != v.bundleID {
            fputs("[display] front disagreement: activation=\(a.bundleID) "
                + "window=\(v.bundleID)\n", stderr)
        }
        if let a = activation, isListed(a.bundleID) { return a }
        if let v = visual, isListed(v.bundleID) { return v }
        return visual ?? activation
    }

    private func handleAppActivated(_ bundleID: String, pid: pid_t) {
        if invertEnabled {
            // Events may INVERT (snappier than waiting for the heartbeat):
            // the list is unconditional certainty, auto-measurement judges
            // unlisted apps. Events NEVER revert — that's the heartbeat's
            // monopoly (poll()).
            if isListed(bundleID) {
                lastHolderSeen = Date()
                ensureInverted(true, holder: bundleID, reason: bundleID)
            } else if autoInvert, bundleID != Self.previewBundle || !previewDarkActive,
                      bundleID != Bundle.main.bundleIdentifier {
                evaluateBrightness(bundleID: bundleID, pid: pid)
            }
        }

        if bundleID == Self.previewBundle {
            if previewDarkActive {
                applyPreviewDarkMode(pid: pid)
                observePreviewWindows(pid: pid)
            }
        } else {
            teardownPreviewObserver()
        }
    }

    // THE HEARTBEAT — the only authority allowed to revert (events only
    // invert). The poll reasons about the ENVELOPE: whoever earned the
    // inversion (the holder) merely has to be SEEN in front once every
    // revertAfter seconds to keep it; sitting still renews every beat.
    // revertAfter must outlast PT's post-inversion rebuild flap (~1-2s of
    // activation churn caused by the display change itself) — that floor
    // is physics, not paranoia; everything else was shrunk to human speed
    // once the hotkey mechanism proved to stick.
    private var pollTimer: Timer?
    private var invertHolder: String?
    private var lastHolderSeen = Date.distantPast
    private static let pollInterval: TimeInterval = 1.0
    private static let revertAfter: TimeInterval = 3.0

    // FAST REVERT CONFIRM: three samples 0.5s apart after a switch-away
    // event. Reverts at ~1.5s instead of the heartbeat's quiet-case pace —
    // still an envelope judgment, never an instant one. Any listed
    // activation bumps the generation and kills the burst.
    private var fastConfirmGeneration = 0
    private var lastRevertAt = Date.distantPast

    private func beginFastRevertConfirm() {
        fastConfirmGeneration += 1
        let generation = fastConfirmGeneration
        var checks = 0
        func step() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, generation == self.fastConfirmGeneration,
                      self.isInverted, self.invertEnabled else { return }
                guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                      !self.isListed(front), front != self.invertHolder else { return }
                checks += 1
                if checks >= 3,
                   Date().timeIntervalSince(self.lastHolderSeen) > 1.4 {
                    self.ensureInverted(false, holder: nil,
                                        reason: "left \(self.invertHolder ?? "invert app") "
                                            + "for \(front), fast")
                } else if checks < 3 {
                    step()
                }
            }
        }
        step()
    }

    private func poll() {
        guard invertEnabled,
              let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        else { return }
        if isListed(front) {
            lastHolderSeen = Date()
            ensureInverted(true, holder: front, reason: front)
        } else if isInverted {
            if front == invertHolder {
                lastHolderSeen = Date()  // auto-inverted app still front
            } else if Date().timeIntervalSince(lastHolderSeen) > Self.revertAfter {
                ensureInverted(false, holder: nil,
                               reason: "left \(invertHolder ?? "invert app") for \(front)")
            }
        }
    }

    // THE TOGGLE LOCKOUT (user-specified): once the display changes, NO
    // code path may change it again for toggleLockout seconds, full stop.
    // The last flicker generators were all "act again quickly" mechanisms
    // — the verify-retry CHORD (a toggle fired on a stale whiteOnBlack
    // read un-inverts a just-inverted screen) and the coherence pulse.
    // Both are deleted. Anything deferred by the lockout converges via the
    // heartbeat, which re-ensures every beat.
    private var lastToggleAt = Date.distantPast
    private static let toggleLockout: TimeInterval = 1.5

    private func ensureInverted(_ wanted: Bool, holder: String?, reason: String) {
        if wanted { invertHolder = holder }
        guard wanted != isInverted else { return }
        // The lockout stands even with a sticking mechanism: one change,
        // then silence — deferred wants converge via the heartbeat
        guard Date().timeIntervalSince(lastToggleAt) >= Self.toggleLockout else { return }
        lastToggleAt = Date()
        applyInversion(wanted)
        isInverted = wanted
        if !wanted {
            invertHolder = nil
            lastRevertAt = Date()
        }
        beginSettleWindow()
        fputs("[display] \(wanted ? "Inverted" : "Reverted") (\(reason))\n", stderr)
        verifyInversion(wanted)
    }

    /// Fires the Invert Colors shortcut via System Events. The hotkey is
    /// a TOGGLE — ensureInverted guarantees this only runs on a genuine
    /// transition, and the lockout guarantees it can't double-fire.
    private func applyInversion(_ wanted: Bool) {
        let shortcut = Self.invertShortcut()
        if let s = shortcut, !s.enabled {
            fputs("[display] the Invert Colors shortcut is DISABLED — enable it "
                + "in Settings, Keyboard, Keyboard Shortcuts, Accessibility\n", stderr)
        }
        let keyCode = shortcut?.keyCode ?? 105
        let mods = shortcut?.modifiers.isEmpty == false
            ? shortcut!.modifiers : ["shift", "command"]
        let using = mods.map { "\($0) down" }.joined(separator: ", ")
        let script = "tell application \"System Events\" to key code \(keyCode) "
            + "using {\(using)}"
        scriptQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            guard (try? process.run()) != nil else {
                fputs("[display] osascript launch failed\n", stderr)
                return
            }
            // Kill-on-timeout watchdog, same policy as the ducker's scripts
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline { usleep(50_000) }
            if process.isRunning { process.terminate() }
        }
    }

    /// Verification NEVER acts on the display (the old retry was a
    /// flicker generator) — it only resyncs bookkeeping and hints. With
    /// the hotkey path, a mismatch means the shortcut didn't fire
    /// (disabled, or the first-run Automation prompt is waiting).
    private func verifyInversion(_ wanted: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.isInverted == wanted else { return }
            let actual = Self.displayIsInverted()
            guard actual != wanted else { return }
            self.isInverted = actual
            fputs("[display] inversion had no effect — check the Invert Colors "
                + "shortcut in Settings, Keyboard, Keyboard Shortcuts, "
                + "Accessibility, and Marduk's Automation permission for "
                + "System Events\n", stderr)
        }
    }

    // MARK: - Brightness auto-detection

    /// One tiny screenshot of the app's frontmost window, mean brightness,
    /// invert/revert decision — guarded so a slow capture landing after
    /// another app switch changes nothing.
    private func evaluateBrightness(bundleID: String, pid: pid_t) {
        Task { [weak self] in
            guard let self else { return }
            var measured: Double?
            do {
                let content = try await SCShareableContent
                    .excludingDesktopWindows(false, onScreenWindowsOnly: true)
                // LARGEST window, not first — an activation that comes with
                // a small dialog up must still measure the document window
                guard let window = content.windows
                    .filter({ $0.owningApplication?.processID == pid && $0.isOnScreen
                                && $0.frame.width > 200 && $0.frame.height > 150 })
                    .max(by: { $0.frame.width * $0.frame.height
                             < $1.frame.width * $1.frame.height }) else { return }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                config.width = 64
                config.height = 40
                config.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config)
                measured = Self.meanBrightness(image)
            } catch {
                if !self.captureFailureLogged {
                    self.captureFailureLogged = true
                    fputs("[display] auto-invert capture failed (Screen Recording "
                        + "permission?): \(error.localizedDescription)\n", stderr)
                }
                return
            }
            guard let measured else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.invertEnabled, self.autoInvert,
                      self.resolveFront()?.bundleID == bundleID else { return }
                // Window captures come from the backing store, BEFORE the
                // display-level inversion filter — the measurement is the
                // app's true brightness either way. (The one observed
                // oscillation was a dialog window getting measured; the
                // largest-window pick fixed it.) Hysteresis keeps boundary
                // apps from flapping across re-measures.
                let wanted = measured > self.autoInvertThreshold
                    - (self.isInverted ? 0.08 : 0)
                let reason = "auto \(bundleID) " + String(format: "%.2f", measured)
                if wanted {
                    self.lastHolderSeen = Date()
                    self.ensureInverted(true, holder: bundleID, reason: reason)
                }
                // Dark verdicts do NOTHING — reverting is the heartbeat's
                // monopoly, and this measurement is just one instant
            }
        }
    }

    /// Mean of the color channels across the image, 0…1. Channel-order
    /// agnostic on purpose (BGRA vs RGBA doesn't matter to a mean), which
    /// is plenty for a bright-or-dark verdict.
    static func meanBrightness(_ image: CGImage) -> Double? {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let bytesPerPixel = image.bitsPerPixel / 8
        guard bytesPerPixel >= 3, image.bitsPerComponent == 8 else { return nil }
        let alphaFirst = image.alphaInfo == .premultipliedFirst
            || image.alphaInfo == .first || image.alphaInfo == .noneSkipFirst
        let colorOffset = alphaFirst && bytesPerPixel == 4 ? 1 : 0
        var total = 0
        var samples = 0
        for y in 0..<image.height {
            let row = y * image.bytesPerRow
            for x in 0..<image.width {
                let p = row + x * bytesPerPixel + colorOffset
                total += Int(bytes[p]) + Int(bytes[p + 1]) + Int(bytes[p + 2])
                samples += 3
            }
        }
        guard samples > 0 else { return nil }
        return Double(total) / Double(samples) / 255.0
    }

    /// Ground truth from the same store Settings writes — no guessing
    /// whether the chord landed.
    static func displayIsInverted() -> Bool {
        let domain = "com.apple.universalaccess" as CFString
        CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue("whiteOnBlack" as CFString, domain)
            as? Bool) ?? false
    }

    // MARK: - Preview "View in Dark Mode"

    /// Press View → View in Dark Mode via the AX menu bar when the focused
    /// window isn't already dark (AXMenuItemMarkChar carries the checkmark).
    /// Off-main: menu walks are synchronous AX IPC.
    private func applyPreviewDarkMode(pid: pid_t) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.3)

            var menuBarRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                      app, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
                  let rawBar = menuBarRef,
                  CFGetTypeID(rawBar) == AXUIElementGetTypeID() else { return }

            // Titles shift across macOS releases — macOS 26 says "Use
            // Dark Appearance for PDF", older Previews "View in Dark
            // Mode" — so search the menu bar for the first title carrying
            // any known phrasing (English-only, a Marduk-wide limit)
            let needles = ["dark appearance", "dark mode"]
            guard let item = needles.lazy.compactMap({ needle in
                Self.findMenuItem(containing: needle,
                                  under: rawBar as! AXUIElement, depth: 6)
            }).first else {
                let viewCount = Self.child(of: rawBar as! AXUIElement, titled: "View")
                    .map { Self.children(of: $0).first.map { Self.children(of: $0).count } ?? 0 }
                fputs("[display] Preview dark: no dark-mode menu item "
                    + "(View menu items: \(viewCount ?? -1))\n", stderr)
                return
            }

            var markRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(
                item, "AXMenuItemMarkChar" as CFString, &markRef)
            if let mark = markRef as? String, !mark.isEmpty {
                return  // already dark — pressing would toggle it back
            }
            if AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
                fputs("[display] Preview dark: applied\n", stderr)
            } else {
                fputs("[display] Preview dark: press failed\n", stderr)
            }
        }
    }

    /// Windows opened while Preview is already front (double-clicking a
    /// second PDF) need the treatment too — the sentinel pattern, scoped
    /// to Preview.
    private func observePreviewWindows(pid: pid_t) {
        guard pid != previewObserverPID else { return }
        teardownPreviewObserver()

        var observer: AXObserver?
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let inverter = Unmanaged<DisplayInverter>.fromOpaque(refcon).takeUnretainedValue()
            guard inverter.previewDarkActive else { return }
            inverter.applyPreviewDarkMode(pid: inverter.previewObserverPID)
        }, &observer) == .success, let observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        AXObserverAddNotification(observer, appElement,
                                  kAXWindowCreatedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(observer), .defaultMode)
        previewObserver = observer
        previewObserverPID = pid
    }

    private func teardownPreviewObserver() {
        if let observer = previewObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        previewObserver = nil
        previewObserverPID = -1
    }

    // MARK: - AX helpers

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, kAXChildrenAttribute as CFString, &ref) == .success,
              let children = ref as? [AXUIElement] else { return [] }
        return children
    }

    /// Depth-limited search of a menu tree for an item whose title
    /// contains `needle` (case-insensitive).
    private static func findMenuItem(containing needle: String,
                                     under element: AXUIElement,
                                     depth: Int) -> AXUIElement? {
        guard depth > 0 else { return nil }
        for child in children(of: element) {
            var titleRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString,
                                              &titleRef)
            if let title = titleRef as? String,
               title.lowercased().contains(needle) {
                return child
            }
            if let found = findMenuItem(containing: needle, under: child,
                                        depth: depth - 1) {
                return found
            }
        }
        return nil
    }

    private static func child(of element: AXUIElement, titled title: String) -> AXUIElement? {
        children(of: element).first { child in
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                      child, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let t = titleRef as? String else { return false }
            return t == title
        }
    }
}
