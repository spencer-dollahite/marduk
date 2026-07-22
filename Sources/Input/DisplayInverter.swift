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
    /// Fired (main queue) the first time a dark-appearance press succeeds
    /// this run — the Daemon speaks the one-time onboarding explanation.
    var onDarkApplied: (() -> Void)?
    /// Fired (main queue, once per session) when System Events refuses
    /// our Apple events (-1743): the Automation grant is denied and
    /// inversion silently can't work — the Daemon speaks it and opens
    /// the Automation pane.
    var onAutomationDenied: (() -> Void)?
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
    /// Did WE fire the toggle that turned the current inversion on?
    /// "The display is inverted" and "Marduk inverted it" are separate
    /// facts, and conflating them is what blinded a user on 2026-07-22.
    ///
    /// Used for EXIT only: teardown hands back an inversion we put there
    /// and leaves anyone else's alone, so quitting can never flip a
    /// display we don't own. It deliberately does NOT gate the heartbeat
    /// — while the user is opted in, Marduk maintains the invariant
    /// "inverted only while something justifies it", so a stranded
    /// inversion (ours from a previous life, or one a crash left behind)
    /// still gets handed back. Without that, a display stranded inverted
    /// stays inverted forever.
    private var weOwnInversion = false
    private var observer: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
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
        // Seed the OBSERVED state so transition math is right — but claim
        // no ownership. An inversion that predates this process is the
        // user's (or a stranded pref), never ours to undo.
        isInverted = Self.displayIsInverted()
        weOwnInversion = false
        fputs("[display] seeded: display inverted = \(isInverted)\n", stderr)

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

        // Death is the one departure that can't lie — a terminated holder
        // has no ghost activations left in it. Revert immediately, no
        // envelope, no burst (field: quitting PT stranded the display
        // inverted; activation-based reverts never fired cleanly for it).
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                      as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            if bundleID == Self.previewBundle {
                // Preview's death is the once-per-document boundary: the
                // manual flips lived in its windows and died with them —
                // a relaunch gets a fresh first-contact pass on every doc
                self.previewDocsLock.lock()
                let count = self.previewTreatedDocs.count
                self.previewTreatedDocs.removeAll()
                self.previewDocsLock.unlock()
                self.teardownPreviewObserver()
                if count > 0 {
                    fputs("[display] Preview quit — cleared \(count) treated "
                        + "document(s)\n", stderr)
                }
            }
            if self.isInverted, bundleID == self.invertHolder {
                self.fastConfirmGeneration += 1
                self.ensureInverted(false, holder: nil, reason: "\(bundleID) quit")
            }
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
        if let observer = terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            terminationObserver = nil
        }
        if let observer = themeObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            themeObserver = nil
        }
        teardownPreviewObserver()
        pollTimer?.invalidate()
        pollTimer = nil
        // Hand back ONLY an inversion we put there, and only after
        // confirming the display is REALLY inverted. The toggle is blind:
        // firing it on a believed-but-false inversion turns a dark screen
        // blinding white, which is exactly what this did in the field on
        // 2026-07-22 — believing a seeded flag it had never earned.
        guard weOwnInversion, isInverted, Self.displayIsInverted() else {
            if isInverted && !weOwnInversion {
                fputs("[display] inverted but not by us — leaving it alone\n",
                      stderr)
            }
            return
        }
        lastToggleAt = Date()
        applyInversion(false)
        isInverted = false
        weOwnInversion = false
        fputs("[display] Reverted inversion on stop\n", stderr)
    }

    /// Live `:config invert off` mid-invert must hand the display back.
    func revertIfInverted() {
        guard isInverted, weOwnInversion, Self.displayIsInverted() else { return }
        lastToggleAt = Date()
        applyInversion(false)
        isInverted = false
        weOwnInversion = false
        fputs("[display] Reverted inversion (invert off)\n", stderr)
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
        // Never act on the display unless the user opted in. The built-in
        // app list is inert until `:config invert on`.
        guard invertEnabled else { return }
        // The lockout stands even with a sticking mechanism: one change,
        // then silence — deferred wants converge via the heartbeat
        guard Date().timeIntervalSince(lastToggleAt) >= Self.toggleLockout else { return }
        // THE TOGGLE IS BLIND: it flips whatever the display is ACTUALLY
        // doing, not what we believe. So re-read the truth before deciding
        // — a stale flag otherwise makes the toggle do the exact opposite
        // of the intent (field 2026-07-22: a "revert" fired on a believed
        // -but-false inversion INVERTED a dark-mode screen). We are past
        // the lockout here, so the pref has settled and this is a
        // precondition check, not the forbidden verify-retry chord.
        let actual = Self.displayIsInverted()
        if actual != isInverted {
            fputs("[display] resync: believed \(isInverted), actually \(actual)\n",
                  stderr)
            isInverted = actual
            if !actual { weOwnInversion = false }
        }
        guard wanted != isInverted else { return }
        lastToggleAt = Date()
        applyInversion(wanted)
        isInverted = wanted
        weOwnInversion = wanted
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
        // The gesture ALWAYS sweeps its own modifiers up afterward — key up
        // on an unpressed modifier is a no-op, and System Events can strand
        // one even when the script completes (field: keys arriving
        // pre-chorded, Cmd+Q dead, apps seemingly frozen). The watchdog
        // cleanup below stays for the killed-mid-gesture case.
        scriptQueue.async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "tell application \"System Events\"",
                                 "-e", "key code \(keyCode) using {\(using)}",
                                 "-e", "key up shift", "-e", "key up command",
                                 "-e", "key up option", "-e", "key up control",
                                 "-e", "end tell"]
            // Capture stderr: a DENIED Automation grant surfaces here as
            // -1743, and it must be SPOKEN, not just logged — the field
            // discovery mode was "the screen stayed bright" (2026-07-22;
            // TCC dropped the grant after the release re-sign + update
            // swap churned the bundle signature twice in one session)
            let errPipe = Pipe()
            process.standardError = errPipe
            guard (try? process.run()) != nil else {
                fputs("[display] osascript launch failed\n", stderr)
                return
            }
            // Kill-on-timeout watchdog. Generous: a first-run Automation
            // prompt legitimately stalls osascript, and killing one
            // MID-GESTURE leaves virtual modifiers stuck down system-wide
            // (field: Cmd+Q stopped working — arriving as Shift+Cmd+Q).
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning && Date() < deadline { usleep(50_000) }
            if process.isRunning {
                process.terminate()
                fputs("[display] invert osascript timed out — releasing "
                    + "modifiers\n", stderr)
                Self.releaseStuckModifiers()
            }
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            if let err = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !err.isEmpty {
                fputs("[display] invert osascript: \(err)\n", stderr)
                if err.contains("-1743") || err.contains("Not authorized") {
                    DispatchQueue.main.async { self?.reportAutomationDenied() }
                }
            }
        }
    }

    /// The Automation grant (Marduk → System Events) is DENIED — every
    /// inversion is a silent no-op until the user re-allows it. Speak it
    /// once per session and let the daemon open the right Settings pane;
    /// a lost permission must introduce itself (the pdfdark principle).
    private var automationDeniedReported = false
    private func reportAutomationDenied() {
        guard !automationDeniedReported else { return }
        automationDeniedReported = true
        onAutomationDenied?()
    }

    /// A killed keystroke script can leave shift/command logically held —
    /// force-release every modifier so one incident can't disable the
    /// keyboard's chords until reboot.
    private static func releaseStuckModifiers() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"System Events\"",
                             "-e", "key up shift", "-e", "key up command",
                             "-e", "key up option", "-e", "key up control",
                             "-e", "end tell"]
        guard (try? process.run()) != nil else { return }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate() }
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
            // Our toggle didn't land, so we own nothing — claiming an
            // inversion that never happened is what makes a later
            // "revert" fire a toggle onto an un-inverted display.
            self.weOwnInversion = actual && self.weOwnInversion
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

    /// Ground truth for Invert Colors — the PUBLIC, live AppKit signal.
    ///
    /// This used to read `com.apple.universalaccess/whiteOnBlack` via
    /// CFPreferences. That key is NOT trustworthy: on macOS 26 it was
    /// found reading TRUE with the display plainly NOT inverted (field
    /// 2026-07-22 — we read another process's store through cfprefsd, and
    /// the key survives as stale legacy state). Every symptom of that
    /// week traces to it: seeded from it, `stop()` fired a "revert" that
    /// INVERTED a dark-mode screen; then resyncing from it made Marduk
    /// refuse to invert Pages at all, because it believed it already had.
    /// NSWorkspace tracks the real accessibility display options live.
    static func displayIsInverted() -> Bool {
        NSWorkspace.shared.accessibilityDisplayShouldInvertColors
    }

    // MARK: - Preview "View in Dark Mode"

    // Opening a PDF fires THREE triggers within ~150ms (raw activation
    // fast path, dwell path, window-created observer) — two presses both
    // reading "unchecked" before the first lands toggled dark-then-light
    // (field flicker). Single-flight: one press per second, all call
    // sites are main-thread.
    private var lastPreviewDarkAttempt = Date.distantPast

    // ONCE PER DOCUMENT PER SESSION (user-specified): after Marduk's
    // first pass on a document, its dark/light state belongs to the USER
    // — a manual flip back to light must survive every later focus cycle.
    // Keyed by the window's AXDocument path; documents the user darkened
    // themselves count as treated (the checkmark says so).
    private let previewDocsLock = NSLock()
    private var previewTreatedDocs = Set<String>()

    private func previewAlreadyTreated(_ path: String) -> Bool {
        previewDocsLock.lock(); defer { previewDocsLock.unlock() }
        return previewTreatedDocs.contains(path)
    }

    private func markPreviewTreated(_ path: String) {
        previewDocsLock.lock(); defer { previewDocsLock.unlock() }
        previewTreatedDocs.insert(path)
    }

    /// Press Preview's dark-appearance menu item via the AX menu bar when
    /// the focused window isn't already dark (AXMenuItemMarkChar carries
    /// the checkmark). Off-main: menu walks are synchronous AX IPC.
    private func applyPreviewDarkMode(pid: pid_t) {
        guard Date().timeIntervalSince(lastPreviewDarkAttempt) > 1.0 else { return }
        lastPreviewDarkAttempt = Date()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15) {
            [weak self] in
            guard let self else { return }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.3)

            // Focused window's document path — the once-per-document key.
            // Pathless windows (no document) fall through to the plain
            // checkmark-guarded behavior with no memory.
            var docPath: String?
            var windowRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                   app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
               let rawWindow = windowRef,
               CFGetTypeID(rawWindow) == AXUIElementGetTypeID() {
                var docRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(
                       rawWindow as! AXUIElement, "AXDocument" as CFString,
                       &docRef) == .success,
                   let doc = docRef as? String {
                    docPath = doc
                }
            }
            if let docPath, self.previewAlreadyTreated(docPath) { return }

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
                // Already dark — the user (or a prior pass) got here first;
                // remember the document so we never argue with them later
                if let docPath { self.markPreviewTreated(docPath) }
                return
            }
            if AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
                if let docPath { self.markPreviewTreated(docPath) }
                fputs("[display] Preview dark: applied"
                    + "\(docPath != nil ? " (once per document)" : "")\n", stderr)
                DispatchQueue.main.async { self.onDarkApplied?() }
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
