import Foundation
import AppKit
import ApplicationServices
import CoreAudio

/// Monitors global keyboard events via CGEventTap.
/// Vim-style modal: starts in NORMAL mode (commands active),
/// `i` enters INSERT mode (keys pass through). In INSERT, a *tapped* Escape
/// belongs to the app (vim, Claude Code, dialogs) and is delivered on key
/// release; a *held* Escape (>= escapeHoldThreshold) returns to NORMAL and
/// the app never sees it.
/// Ctrl+Option+M toggles Marduk on/off entirely.
final class KeyboardMonitor {
    typealias SpeakHandler = (String) -> Void
    /// The stop's REASON rides along — a short fixed word, structured
    /// vocabulary rather than user content. A silenced read leaves no
    /// other trace, and three passes at the swallowed read were spent
    /// guessing which caller had fired one.
    typealias StopHandler = (String) -> Void
    typealias AnnounceHandler = (String) -> Void
    typealias UpdateHandler = () -> Void

    enum Mode { case normal, insert, visual, visualLine, command }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// The most recent frontmost app that wasn't Marduk — what the user
    /// was actually in before a picker stole focus.
    private(set) var lastForeignApp: (name: String, id: String)?

    /// True once the CGEventTap exists (Accessibility granted). The daemon
    /// gates the first-run welcome on this — arming a t/p/s question with no
    /// tap silently loses the user's answer to the frontmost app.
    var tapAlive: Bool { eventTap != nil }
    /// Fired when the tap comes up LATE (retry after a permission grant).
    /// When set, the daemon owns the spoken feedback — the deferred welcome
    /// or the generic "active" line; unset falls back to the generic line.
    var onTapEstablished: (() -> Void)?
    private var tapWatchdog: DispatchSourceTimer?
    private var tapRetry: DispatchSourceTimer?
    // FAIL-OPEN: when Marduk's main thread can't process keys promptly,
    // the correct assistive behavior is to stop intercepting entirely —
    // the user keeps a fully working raw keyboard while Marduk degrades.
    // Field incident: a silent auto-update's swift build starved the main
    // thread; withheld burst keys were never released, macOS oscillated
    // the tap, and the machine's keyboard was half-dead until a reboot.
    // failOpen is touched from main AND the sentinel queue — lock it.
    private let failOpenLock = NSLock()
    private var failOpenReasons = Set<String>()
    /// Monotonic UPTIME nanoseconds, never wall clock. `Date()` keeps
    /// counting while the Mac is asleep, so every wake reported a main
    /// thread "lagging" for the whole nap — the field log shows 777s, 911s,
    /// 1028s — and failed the tap open on a machine that was simply
    /// closed. DispatchTime is mach_absolute_time, which stops with the
    /// system, so a lag reading now only ever means real congestion.
    private var lastMainBeat = DispatchTime.now().uptimeNanoseconds
    private var maxMainLag: TimeInterval = 0  // failOpenLock-guarded
    private var latencySentinel: DispatchSourceTimer?
    private var onSpeak: SpeakHandler?
    private var onStop: StopHandler?
    private var onAnnounce: AnnounceHandler?
    private var onUpdate: UpdateHandler?
    private var isSpeaking: () -> Bool = { false }
    private var isReadActive: () -> Bool = { false }
    private var isReadPaused: () -> Bool = { false }
    /// A read handed to the synthesizer that has not made a sound yet.
    /// Distinct from `isSpeaking`, which is true the moment the queue
    /// accepts an utterance — see `SpeechHealth.isSilentStartup`.
    private var isReadStarting: () -> Bool = { false }
    private var onPauseToggle: (() -> Void)?
    private var stopped = false

    private(set) var isEnabled = true {
        didSet {
            if isEnabled != oldValue { onEnabledChange?(isEnabled) }
            // Disengaged means hands off every other process too
            if !isEnabled { AXNudge.shared.restoreAll(reason: "disengaged") }
        }
    }
    private(set) var mode: Mode = .normal {
        didSet { if mode != oldValue { onModeChange?(mode) } }
    }

    // Mode/enabled observers (fired synchronously from the tap callback —
    // handlers must dispatch their own work and never block)
    var onModeChange: ((Mode) -> Void)?
    var onEnabledChange: ((Bool) -> Void)?

    // COMMAND mode (":"). Buffer is main-thread-only like all tap state.
    // Callbacks are dispatched to main; the palette/daemon react there.
    var onCommandSubmit: ((String) -> Void)?
    // (buffer, canAutoAccept) — auto-accept must only fire on typed chars,
    // never on deletions, or removing an auto-added space would re-add it.
    var onCommandChange: ((String, Bool) -> Void)?
    var onCommandTab: (() -> Void)?
    var onCommandSelect: ((Int) -> Void)?
    var onCommandHelp: (() -> Void)?    // "?" — speak options, even when none
    var onCommandIdle: (() -> Void)?    // typing pause — speak options if any
    var onUpdateCheck: (() -> Void)?    // single u — check + speak release notes
    // dd — cut a patch release (source installs only). On release/Homebrew
    // machines the gesture DOES NOT EXIST: releaseAvailable stays false,
    // the burst branch never fires, and double-d words ("add", "buddy")
    // keep their typing-rescue behavior — zero new surface for strangers
    // (the Firefox-n precedent: a command letter only where it means
    // something).
    var onCutRelease: (() -> Void)?
    // rr — say the last utterance again (announcement or read). Speech is
    // the only output this product has and it vanishes as it finishes;
    // there is no scrollback to glance back at.
    var onReplay: (() -> Void)?
    var releaseAvailable = false
    private var commandIdleTimer: DispatchWorkItem?
    var typingEchoEnabled = false    // speak chars typed in INSERT
    var commandEchoEnabled = true    // speak chars typed after ":"
    var speedKeysEnabled = false     // Option+Up/Down nudge speech rate (NORMAL/VISUAL)
    var toggleEarconEnabled = false  // Ctrl+Option+M bloops instead of speaking
    var onRateChange: ((Float) -> Void)?  // signed rate delta from the speed keys

    // Read motions (default ON, `:config readmotions off` disables): vim
    // navigation inside an active read — b/w/h/l word, (/) sentence, j/k
    // line, {/} paragraph, digits count, / and ? search. While enabled,
    // an active read CAPTURES the keyboard from any mode (READING is a
    // real mode: i and held Escape are the only exits); with the setting
    // off, every key keeps its normal behavior. State is main-thread-only
    // like all tap state.
    var readMotionsEnabled = false {
        didSet {
            // Turned off mid-read (socket-side :config): drop the capture,
            // or the motions would keep firing with the feature off
            if !readMotionsEnabled { readingCapture = false }
        }
    }
    // True while a read owns the keyboard. Set by readStateChanged (the
    // engine's readActive didSet, synchronous on main) — the tap callback
    // reads it directly. The underlying `mode` is left untouched while
    // capturing; only the explicit exits (i, Escape) change it, so a read
    // that ends naturally returns the user exactly where they were.
    // onReadingChange fires on actual flips, sometimes synchronously from
    // the tap callback — handlers must only dispatch, never block (same
    // contract as onModeChange/onEnabledChange). Drives the overlay's
    // purple READING color.
    var onReadingChange: ((Bool) -> Void)?
    private(set) var readingCapture = false {
        didSet { if readingCapture != oldValue { onReadingChange?(readingCapture) } }
    }
    var onReadJump: ((ReadUnit, ReadDirection, Int) -> Void)?
    var onReadSearch: ((String, ReadDirection) -> Void)?
    var onReadSearchBegin: (() -> Void)?    // pause the read while typing
    var onReadSearchCancel: (() -> Void)?   // Escape/empty — resume in place
    var onReadSearchEcho: ((String) -> Void)?  // echo keystrokes OVER the paused read
    private var readSearchDirection: ReadDirection?  // non-nil = entry state active
    private var readSearchBuffer = ""
    private var readMotionCount = 0          // pending vim count, e.g. 3(
    private var pendingReadG = false         // first g of gg seen (no timeout — vim style)
    var onReadJumpEdge: ((ReadDirection) -> Void)?   // gg (.back) / G (.forward)
    var onReadLineStart: (() -> Void)?               // bare 0 — restart the line
    var onReadSpell: ((ReadUnit) -> Void)?           // z word / Z sentence
    // `.` repeats the last motion (vim). Repeating a search re-hunts from
    // the new position — vim's n by another name, without the Firefox-n
    // collision. Persists across reads, like vim's dot across edits.
    private enum ReadAction {
        case jump(ReadUnit, ReadDirection, Int)
        case edge(ReadDirection)
        case search(String, ReadDirection)
        case find(Character, ReadDirection)
        case pageStep(Int)
        case heading(HeadingMotion, Int)
    }
    var onReadPageStep: ((Int) -> Void)?      // Ctrl+F/Ctrl+B, ±count pages
    var onReadPageAbsolute: ((Int) -> Void)?  // 12G — page twelve
    var onReadPercent: ((Int) -> Void)?       // 50% — jump to N percent
    var onReadPosition: (() -> Void)?
    /// Ctrl+O (.back) / Ctrl+I (.forward) — vim's jumplist, with a count.
    var onReadJumpList: ((ReadDirection, Int) -> Void)?         // Ctrl+G — where am I
    // PDF read: paged text, 1-based start page, outline headings (page, level)
    var onSpeakPaged: ((PagedText, Int, [(page: Int, level: Int)]) -> Void)?
    // Full-document read: complete text + UTF-16 start offset. The daemon
    // decides plain vs synthetic-paged (huge text chunks into pages, so
    // the whole document is reachable). Anchored web reads stay on onSpeak
    // — their line→anchor scroll mapping assumes unwindowed text.
    var onSpeakDocument: ((String, Int) -> Void)?
    private var lastReadAction: ReadAction?
    var onReadFind: ((Character, ReadDirection) -> Void)?  // f/F + char
    private var pendingReadFind: ReadDirection?  // f pressed, awaiting the target char
    var onReadHeading: ((HeadingMotion, Int) -> Void)?  // ]] [[ ][ [] ]u
    // A lone ] or [ pends its pair vim-style (no timeout); any key that
    // isn't the pair's second half clears it and acts normally.
    private enum PendingBracket { case open, close }  // [ armed / ] armed
    private var pendingReadBracket: PendingBracket?
    // Harvested heading lines (raw line index → level) for the read that
    // just started — the daemon relays them to SpeechEngine, which maps
    // them onto the processed text.
    var onHarvestHeadings: (([(line: Int, level: Int)]) -> Void)?
    // The daemon's per-read generation (bumped on every new read) — the
    // async rich-text heading harvest captures it at read start and
    // drops its result if any newer read won meanwhile. Main-thread only.
    var readGenerationProvider: (() -> Int)?

    /// Drop every half-entered read-motion state (count, pending gg,
    /// armed find/bracket) — the exits, toggles, and read end all need this.
    private func resetReadMotionState() {
        readMotionCount = 0
        pendingReadG = false
        pendingReadFind = nil
        pendingReadBracket = nil
    }

    // Dialog-focus question (armed by the daemon when a dialog
    // announcement carries the a/o/n/s consent tail). Main-thread-only
    // like all tap state; answered/expired/superseded → the closure is
    // released, and with it the daemon's retained dialog target.
    private var pendingQuestionAnswer: ((Character) -> Void)?
    private var pendingQuestionKeys: Set<Character> = []
    private var questionTimeout: DispatchWorkItem?
    private static let questionWindow: TimeInterval = 20

    /// Arm a one-key spoken-question capture (dialog-focus a/o/n/s, the
    /// first-run t/p/s gateway, onboarding y/n). `keys` are lowercase
    /// answer characters. Main thread only. A new question replaces an
    /// armed one; the timeout bounds how long the answer keys shadow their
    /// normal meanings. RESTART the window with extendQuestionWindow when
    /// the spoken prompt finishes — the clock must not tick while the
    /// prompt is still being read aloud (field: the user listened to the
    /// whole pitch before answering).
    func armQuestion(keys: Set<Character>, onAnswer: @escaping (Character) -> Void) {
        cancelQuestion()
        pendingQuestionKeys = keys
        pendingQuestionAnswer = onAnswer
        scheduleQuestionTimeout()
    }

    /// Restart the answer window (no-op when nothing is armed).
    func extendQuestionWindow() {
        guard pendingQuestionAnswer != nil else { return }
        scheduleQuestionTimeout()
    }

    private func scheduleQuestionTimeout() {
        questionTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.cancelQuestion() }
        questionTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.questionWindow,
                                      execute: work)
    }

    func cancelQuestion() {
        questionTimeout?.cancel()
        questionTimeout = nil
        pendingQuestionAnswer = nil
        pendingQuestionKeys = []
    }

    // Firefox Reader narration handoff (`n` in NORMAL while Firefox is
    // frontmost). true = Marduk stops its own speech and holds media
    // paused while Firefox's Narrate reads; false = release. State is
    // main-thread-only like all tap state.
    var onNarrate: ((Bool) -> Void)?
    private var narrationActive = false

    // NEWS mode (`n` outside Firefox — newsboat handoff). While active the
    // tap owns the list keys (j/k/Enter/h/q/r/R/o, digits, gg/G) and the
    // daemon's NewsReader mirrors newsboat's TUI; an article read layers
    // the READING capture above this. State is main-thread-only like all
    // tap state; the daemon arms it via setNewsActive once the mirror is
    // loaded, and every exit path (Escape/n, Ctrl+Option+M, app switch)
    // clears it here FIRST so no further keys are eaten.
    var onNewsOpen: (() -> Void)?
    var onNewsCommand: ((NewsCommand) -> Void)?
    private(set) var newsActive = false
    private var newsCount = 0
    private var pendingNewsG = false
    // d deletes IMMEDIATELY; a second d inside this window is swallowed,
    // so bare d and vim's dd both delete exactly one article
    private var lastNewsDelete = Date.distantPast
    // "/" and "?" — a COMMAND-mode-sibling query editor (the read-search
    // pattern): non-nil direction = entry state active
    private var newsSearchDirection: ReadDirection?
    private var newsSearchBuffer = ""
    static let newsHostBundle = "com.apple.Terminal"

    /// Daemon-side arm/disarm (main thread). Clearing always drops the
    /// half-entered count/gg/search state with it.
    func setNewsActive(_ active: Bool) {
        newsActive = active
        newsCount = 0
        pendingNewsG = false
        lastNewsDelete = .distantPast
        newsSearchDirection = nil
        newsSearchBuffer = ""
    }

    /// Synthetic keys for the NewsReader (arrows/Enter/q into newsboat's
    /// Terminal). Marker-tagged like every synthetic post, main thread.
    func postNewsKeys(keycode: CGKeyCode, shift: Bool = false, count: Int = 1) {
        postKey(keycode: keycode, shift: shift, count: count)
    }

    // Extension gates (:config news/stocks/brief off): a disabled
    // extension's key falls through to its old meaning — n and d to the
    // NORMAL buzz, S to the hover toggle — zero surface, the
    // releaseAvailable pattern.
    var newsExtensionEnabled = true
    var stocksExtensionEnabled = true
    var briefExtensionEnabled = true
    var describeExtensionEnabled = true

    /// DAILY BRIEF (`d`): a lone d, resolved on burst expiry exactly like
    /// s/t/u/n. `d` is deliberately NOT one of BurstPolicy's command
    /// letters, so words keep their typing rescue — and on source installs
    /// the `dd` release gesture still resolves inside the burst layer,
    /// before a lone d can ever reach here.
    var onBriefOpen: (() -> Void)?
    var onDescribe: (() -> Void)?

    // STOCKS mode (`S` — Marduk-native watchlist, no external app, no
    // key posting). Same shape as NEWS: daemon arms via setStocksActive,
    // the tap consumes list keys and emits semantic StocksCommands.
    // stocksHostBundle remembers which app was front at arm time so the
    // command palette's activate/deactivate round trip (the a/b/s
    // prefill flow) doesn't read as "the user left".
    var onStocksOpen: (() -> Void)?
    var onStocksCommand: ((StocksCommand) -> Void)?
    private(set) var stocksActive = false
    private var stocksCount = 0
    private var pendingStocksG = false
    private var pendingStocksD = false   // first d of dd (remove ticker)
    private var stocksHostBundle = ""

    func setStocksActive(_ active: Bool) {
        stocksActive = active
        stocksCount = 0
        pendingStocksG = false
        pendingStocksD = false
        if active { stocksHostBundle = frontmostBundleID }
    }

    /// Enter COMMAND mode with a prefilled buffer (the stocks a/b/s flow:
    /// "stock add " and friends — the user types the rest and Returns).
    /// Main thread only.
    func openCommandLine(prefill: String) {
        guard isEnabled, mode != .command else { return }
        enterCommandMode()
        commandBuffer = prefill
        DispatchQueue.main.async { [self] in onCommandChange?(prefill, false) }
    }
    // Cached by a workspace observer so the tap callback can gate the `n`
    // command on the frontmost app without querying anything in-callback
    private var frontmostBundleID =
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    // The PID beside it, for the cursor-placement ledger (same rule: the
    // tap callback reads the cache, never NSWorkspace)
    private var frontmostPID: pid_t =
        NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    /// The cached frontmost bundle ID for consumers outside the tap (the
    /// speech engine scopes system pronunciation entries per app).
    var frontmostApp: String? { frontmostBundleID.isEmpty ? nil : frontmostBundleID }
    private var workspaceObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var isFirefoxFrontmost: Bool { frontmostBundleID == "org.mozilla.firefox" }

    /// Re-read the REAL frontmost app and resync the cache. Main thread
    /// only — NSWorkspace is fine here, never in the tap callback. The
    /// didActivate feed flaps under churn (the display inverter logs the
    /// disagreements as "front disagreement"), and the Firefox-gated keys
    /// are exactly where a stale reading turns into an eaten key: a cache
    /// stuck on Firefox routed n into the Narrate gate, which buzzed
    /// instead of opening news (field 2026-08-05). Confirm against
    /// reality before any Firefox-gated action fires.
    @discardableResult
    private func resyncFrontmost() -> String {
        if let app = NSWorkspace.shared.frontmostApplication {
            frontmostBundleID = app.bundleIdentifier ?? ""
            frontmostPID = app.processIdentifier
        }
        return frontmostBundleID
    }
    private var commandBuffer = ""
    // After an auto-expand ("posi" → "config position "), the user may still
    // be typing the rest of the word — those chars are absorbed, not appended.
    private var commandAbsorbTail: [Character] = []
    /// How many times the NORMAL-mode buzz has explained itself. After
    /// `buzzHintLimit` the buzz is bare — the earcon alone says "not a
    /// command" and a user who has heard the sentence three times knows
    /// what it means; repeating it forever would talk over their work.
    /// Cached in memory because the tap callback reads it (never file I/O
    /// there) and flushed to the marker on the main queue after each hint.
    private var buzzHintsSpoken = OnceMarker.count(KeyboardMonitor.buzzHintMarker)
    static let buzzHintMarker = "buzz-hints"
    static let buzzHintLimit = 3

    // `s` — Marduk-native pointer hover speech (HoverSpeech, daemon-owned):
    // the reading voice at the user's rate/pitch, replacing the macOS
    // hover feature (whose separately-configured voice never matched)
    var onHoverToggle: (() -> Void)?

    // Typing-burst rescue (NORMAL mode). Unmodified letter keyDowns are
    // withheld briefly instead of executing immediately; a quick burst that
    // contains a non-command letter means the user forgot they're in NORMAL
    // and started typing — switch to INSERT and replay the withheld keys so
    // nothing is lost and no command fires. All of this state is
    // main-thread-only (the tap callback and the decision timer both run on
    // the main runloop), same argument as the Escape tap/hold state below.
    private var burstBuffer: [CGEvent] = []   // copies of withheld keyDowns, in order
    private var burstTimer: DispatchWorkItem?
    private var isFlushingBurst = false        // redispatch in progress — bypass the hook
    var typingBurstThreshold: TimeInterval = 0.3
    var typingRescueEnabled = true

    // Replay-in-flight rollover: real keys arriving between the INSERT
    // decision and the async replay post must be swallowed and appended,
    // or the app would receive them before the replayed burst (the same
    // ordering hazard the Escape rollover solves). A non-empty queue IS the
    // replay-pending state — no separate flag that could desync.
    private var replayQueue: [CGEvent] = []    // marker-tagged, ready to post

    // Tap/hold Escape in INSERT mode. The keyDown is withheld until we know
    // which gesture it is: keyUp before the threshold = tap (deliver a
    // synthetic Escape to the app), timer firing first = hold (→ NORMAL,
    // swallow everything including the trailing keyUp). Both the tap callback
    // and the timer run on the main thread, so this state is race-free.
    private var pendingEscapeHold: DispatchWorkItem?
    private var escapeHoldFired = false
    var escapeHoldThreshold: TimeInterval = 0.4

    // Tap/hold Escape in READING capture: tap = pause/resume (same as
    // Space), hold = stop the read and return to NORMAL. Same threshold
    // and the same escapeHoldFired keyUp-swallow as the INSERT machinery;
    // the two pendings are mutually exclusive (different modes).
    private var pendingReadingEscape: DispatchWorkItem?

    // Visual mode count prefix (e.g. V3j)
    private var pendingCount: Int = 0

    // Whether the current visual session actually extended a selection.
    // Exiting visual mode collapses via a synthetic Right-arrow in non-AX
    // apps; posting that when nothing was ever selected would move the
    // user's caret for no reason (v then Escape must be a no-op).
    private var visualDidExtendSelection = false

    // Suppress autorepeats of the `i` keypress that entered INSERT mode
    private var suppressInsertEntryRepeat = false

    // Marker to identify our own synthetic key events so the tap ignores them
    private static let syntheticMarker: Int64 = 0x4D52444B // "MRDK"

    // MARK: - Cursor-placement ledger
    //
    // AX cannot say WHO put the caret where it is: a reopened Pages doc
    // restores an interior insertion point that is byte-identical to a
    // clicked one, and R trusting it started reads mid-document in
    // windows the user had never touched. But Marduk owns the event tap,
    // so "the user actually placed the cursor" is observable: a click or
    // a delivered keystroke IN THAT WINDOW since it appeared. R's guess
    // rungs (pointer, caret, row estimate) only run when the ledger holds
    // such evidence; a fresh window reads from the top. Granularity is
    // per app AND per window: typing in doc A never blesses doc B's
    // restored caret. Every unknown degrades toward trusting the caret —
    // today's behavior — because a wrongly-forced top strands a working
    // caret with no gesture back, while a wrongly-trusted caret is the
    // status quo. All state is main-thread (tap callback + main queue).
    private let monitorStart = Date()
    private struct ClickRecord {
        let pid: pid_t
        let point: CGPoint  // CGEvent.location — global, top-left origin
    }
    // Clicks are FACTS recorded cheaply and judged only at R time, by
    // geometry against the element's frame: a click into the text area
    // placed the caret; clicks in the template chooser, an open panel, or
    // the toolbar did not, and blanket-counting them would defeat the
    // ledger for the exact fresh-document case it exists for. Geometry
    // makes clicks inherently per-window. A short ring suffices — the
    // caret-placing click is never far behind an R that means "here".
    private var recentClicks: [ClickRecord] = []
    private static let clickLedgerCap = 16
    // Typed evidence: a delivered (passed-through, unmodified) keyDown
    // marks the app's FOCUSED window, fetched off-main and debounced so a
    // typing burst costs one AX round-trip. Window identity is the
    // AXUIElement token (CFEqual); a fetch failure marks the whole app
    // instead — the safe, coarser blessing.
    private var typedApps = Set<pid_t>()
    private var typedWindows: [pid_t: [AXUIElement]] = [:]
    private var lastWindowMark: [pid_t: Date] = [:]
    private static let windowMarkDebounce: TimeInterval = 3
    private static let typedWindowCap = 8
    // Pre-watch window snapshots (field 2026-07-31: the daemon restarts
    // on every self-update, so Pages predates the monitor in almost every
    // real session — an app-level launchDate gate made the ledger inert
    // and a brand-new doc in a long-running Pages still read from the
    // pointer). An app's HISTORY is unknowable, but its window set at the
    // moment evidence collection begins is enumerable: a window in the
    // snapshot keeps the old trust-the-caret behavior; a window absent
    // from a real snapshot appeared under our watch and must earn its
    // caret like any fresh window. No snapshot (sweep failed, AX denied,
    // app appeared mid-sweep) → unknown → trust the caret.
    private var prewatchWindows: [pid_t: [AXUIElement]] = [:]

    // macOS keycodes for digit keys 0-9
    private static let digitKeyCodes: [Int64: Int] = [
        29: 0, 18: 1, 19: 2, 20: 3, 21: 4,
        23: 5, 22: 6, 26: 7, 28: 8, 25: 9
    ]

    // AX-based visual selection state (for Terminal and apps where Shift+Arrow doesn't select)
    private struct VisualAXState {
        let element: AXUIElement
        let text: NSString  // UTF-16 indexed to match AX API
        var anchor: Int     // character offset where visual mode started
        var cursor: Int     // current end of selection
    }
    private var visualAXState: VisualAXState?

    func start(
        onSpeak: @escaping SpeakHandler,
        onStop: @escaping StopHandler,
        onAnnounce: @escaping AnnounceHandler,
        onUpdate: @escaping UpdateHandler,
        isSpeaking: @escaping () -> Bool,
        isReadActive: @escaping () -> Bool = { false },
        isReadPaused: @escaping () -> Bool = { false },
        isReadStarting: @escaping () -> Bool = { false },
        onPauseToggle: (() -> Void)? = nil
    ) {
        self.onSpeak = onSpeak
        self.onStop = onStop
        self.onAnnounce = onAnnounce
        self.onUpdate = onUpdate
        self.isSpeaking = isSpeaking
        self.isReadActive = isReadActive
        self.isReadPaused = isReadPaused
        self.isReadStarting = isReadStarting
        self.onPauseToggle = onPauseToggle

        // Keep the frontmost-app cache warm for the `n` narration gate
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            frontmostBundleID = app?.bundleIdentifier ?? ""
            frontmostPID = app?.processIdentifier ?? 0
            // Remember the last app that ISN'T us: the command palette
            // activates Marduk to take key focus, so by the time a picker
            // opens, NSWorkspace's idea of "frontmost" is Marduk. The app
            // picker needs whoever the user was actually working in.
            if let app, let id = app.bundleIdentifier,
               id != Bundle.main.bundleIdentifier {
                lastForeignApp = (app.localizedName ?? id, id)
            }
            // NEWS mode is anchored to its Terminal window: switching to
            // any other app (except Marduk itself — the palette activates
            // us) stands the mirror down, or captured j/k would eat the
            // user's keys in the app they switched to. Silent by design:
            // `o` hands off to the browser this way on purpose.
            if newsActive, let id = app?.bundleIdentifier,
               id != Self.newsHostBundle, id != Bundle.main.bundleIdentifier {
                setNewsActive(false)
                fputs("[keyboard] news — app switch, standing down\n", stderr)
                onNewsCommand?(.exit)
            }
            // STOCKS likewise stands down when the user moves on — except
            // to Marduk itself (palette) or back to the app they were in
            // when stocks opened (the palette hide reactivates it).
            if stocksActive, let id = app?.bundleIdentifier,
               id != stocksHostBundle, id != Bundle.main.bundleIdentifier {
                setStocksActive(false)
                fputs("[keyboard] stocks — app switch, standing down\n", stderr)
                onStocksCommand?(.exit)
            }
        }

        // A quit app owes nothing and keeps nothing: its ledger rows (window
        // tokens, typed marks, snapshots) and any AX flag we set on it go
        // with it. Keyed by PID, so a recycled PID must never inherit a
        // dead app's evidence — and dictionaries that only ever grow are
        // how a daemon that runs for weeks turns into a slow one.
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                      as? NSRunningApplication else { return }
            self.forgetProcess(app.processIdentifier)
        }

        if createTap() {
            fputs("[keyboard] NORMAL mode (Ctrl+Option+M to disable, i for INSERT)\n", stderr)
            sweepPrewatchWindows()
        } else {
            // A dead tap is invisible to a screen-reader user — say it out
            // loud (speech needs no Accessibility permission) and keep
            // retrying so a grant takes effect without a daemon restart.
            fputs("[keyboard] Failed to create event tap — check Accessibility permission\n", stderr)
            onAnnounce("Keyboard commands unavailable. Grant Marduk Accessibility permission in System Settings.")
            scheduleTapRetry()
        }
    }

    private func createTap() -> Bool {
        // keyUp is needed to distinguish a tapped Escape from a held one;
        // leftMouseDown feeds the cursor-placement ledger (recorded and
        // passed straight through — clicks are never withheld)
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: KeyboardMonitor.eventCallback,
            userInfo: refcon
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Self-heal: macOS silently disables event taps it deems unresponsive.
        // We re-enable on the tapDisabledByTimeout event, but that notification
        // only arrives with the NEXT event and can be missed entirely — leaving
        // Marduk deaf until restart. Poll as a backstop.
        let watchdog = DispatchSource.makeTimerSource(queue: .main)
        watchdog.schedule(deadline: .now() + 5, repeating: 5)
        watchdog.setEventHandler { [weak self] in
            guard let self, !self.stopped, let tap = self.eventTap else { return }
            self.failOpenLock.lock()
            let open = !self.failOpenReasons.isEmpty
            self.failOpenLock.unlock()
            if !open, !CGEvent.tapIsEnabled(tap: tap) {
                fputs("[keyboard] event tap was disabled — re-enabling\n", stderr)
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        watchdog.resume()
        tapWatchdog = watchdog
        startLatencySentinel()
        return true
    }

    // MARK: - Fail-open (never half-strangle the keyboard)

    /// Reasons stack: the sentinel and the updater can each hold the tap
    /// open independently; it re-arms only when every reason clears.
    /// Callable from any thread — CGEvent.tapEnable is thread-safe, and
    /// dispatching to a congested main thread would defeat the point.
    func beginFailOpen(reason: String) {
        failOpenLock.lock()
        let wasOpen = !failOpenReasons.isEmpty
        failOpenReasons.insert(reason)
        failOpenLock.unlock()
        guard !wasOpen, let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        fputs("[keyboard] FAIL-OPEN (\(reason)) — keys pass through raw\n", stderr)
    }

    func endFailOpen(reason: String) {
        failOpenLock.lock()
        failOpenReasons.remove(reason)
        let nowClear = failOpenReasons.isEmpty
        failOpenLock.unlock()
        guard nowClear, !stopped, let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        fputs("[keyboard] fail-open ended (\(reason)) — tap re-armed\n", stderr)
    }

    /// A background heartbeat measures MAIN QUEUE latency directly: a
    /// marker is dispatched to main every beat; if the previous marker
    /// hasn't run after the threshold, main is congested and the tap
    /// fails open until markers flow again. Runs entirely off-main.
    private func startLatencySentinel() {
        guard latencySentinel == nil else { return }
        failOpenLock.lock()
        lastMainBeat = DispatchTime.now().uptimeNanoseconds
        failOpenLock.unlock()
        let sentinel = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.marduk.latency", qos: .userInitiated))
        sentinel.schedule(deadline: .now() + 2, repeating: 1.5)
        sentinel.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.failOpenLock.lock()
                self.lastMainBeat = DispatchTime.now().uptimeNanoseconds
                self.failOpenLock.unlock()
            }
            self.failOpenLock.lock()
            let lag = Double(DispatchTime.now().uptimeNanoseconds
                             &- self.lastMainBeat) / 1_000_000_000
            let tripped = self.failOpenReasons.contains("main-thread congestion")
            // The worst lag since the last health reading: a main thread
            // that stalls for 2s never trips the 4s fail-open, yet every
            // key waits on it — the health line reports it
            if lag > self.maxMainLag { self.maxMainLag = lag }
            self.failOpenLock.unlock()
            if lag > 4, !tripped {
                fputs("[keyboard] main thread lagging \(String(format: "%.1f", lag))s\n",
                      stderr)
                self.beginFailOpen(reason: "main-thread congestion")
            } else if lag < 1, tripped {
                self.endFailOpen(reason: "main-thread congestion")
            }
        }
        sentinel.resume()
        latencySentinel = sentinel
    }

    /// Worst main-queue lag observed by the sentinel since the last call,
    /// then reset. Any thread (the health monitor reads it off its own queue).
    func drainMaxMainLag() -> TimeInterval {
        failOpenLock.lock(); defer { failOpenLock.unlock() }
        let worst = maxMainLag
        maxMainLag = 0
        return worst
    }

    private func scheduleTapRetry() {
        let retry = DispatchSource.makeTimerSource(queue: .main)
        retry.schedule(deadline: .now() + 10, repeating: 10)
        retry.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            if self.createTap() {
                self.tapRetry?.cancel()
                self.tapRetry = nil
                fputs("[keyboard] Event tap created after permission grant\n", stderr)
                // Evidence collection starts NOW — windows the user
                // touched during the tap-less wait were invisible to the
                // ledger, and a fresh snapshot files them as pre-watch
                // (trusted), the safe direction.
                self.sweepPrewatchWindows()
                if let established = self.onTapEstablished {
                    established()
                } else {
                    self.onAnnounce?("Keyboard commands active.")
                }
            }
        }
        retry.resume()
        tapRetry = retry
    }

    func stop() {
        stopped = true
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
        if let observer = terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            terminationObserver = nil
        }
        // Synchronous: a dispatched restore would die with the process
        AXNudge.shared.restoreAllNow(reason: "shutdown")
        tapWatchdog?.cancel()
        tapWatchdog = nil
        latencySentinel?.cancel()
        latencySentinel = nil
        tapRetry?.cancel()
        tapRetry = nil
        commandBuffer = ""
        commandIdleTimer?.cancel()
        readSearchDirection = nil
        readSearchBuffer = ""
        resetReadMotionState()
        readingCapture = false
        pendingReadingEscape?.cancel()
        pendingReadingEscape = nil
        discardBurstAndReplay()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Event Tap Callback

    private static let eventCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon = refcon else { return Unmanaged.passRetained(event) }
        let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
        let result = monitor.handleEvent(type: type, event: event)
        // Cursor-placement ledger, at the one exit every event shares: a
        // keyDown that PASSED (result non-nil) reached the app — consumed
        // commands, withheld bursts, and buzzed keys never mark. Synthetic
        // replays deliberately count: a rescued typing burst IS the user
        // typing into that window.
        if result != nil, type == .keyDown { monitor.noteDeliveredKey(event) }
        return result
    }

    // Keep callback lightweight — dispatch all side effects to main queue
    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if stopped { return pass }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }

        // Clicks feed the placement ledger and pass untouched — an array
        // append, nothing else (callback hygiene). Recorded against the
        // cached frontmost PID: an activating click can attribute to the
        // app being LEFT, but that click rarely places a caret anyway and
        // the user's actual caret click — in the now-front app — records
        // correctly. Recorded even while Marduk is toggled off (pure data,
        // no AX): interaction is interaction.
        if type == .leftMouseDown {
            noteClick(at: event.location)
            return pass
        }

        guard type == .keyDown || type == .keyUp else { return pass }

        // Pass through our own synthetic key events (visual mode selection,
        // tapped-Escape delivery)
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return pass
        }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)

        // keyUps only matter for the Escape tap/hold state machine
        if type == .keyUp {
            if keycode == 53 { return handleEscapeKeyUp(pass: pass) }
            return pass
        }

        let flags = event.flags
        let hasOption = flags.contains(.maskAlternate)
        let hasControl = flags.contains(.maskControl)
        let hasCommand = flags.contains(.maskCommand)
        // Key autorepeat must not re-trigger one-shot/toggle commands: a held
        // Option+Escape's repeat event would see isSpeaking == true and stop
        // the very read it just started ("speech randomly cuts out").
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        // === Always-active shortcuts ===

        // Option+Escape — speak selection / stop speech. A PAUSED read is
        // silent but still reports isSpeaking — before Escape-tap-pause
        // existed that state was rare; now it's routine, and letting it
        // swallow the press ("stop" nothing audible) made chained selection
        // reads feel completely broken. Paused = the user obviously wants
        // the new selection: clear the old read AND read in one press.
        // Audibly speaking = the press means "silence that", unchanged.
        if keycode == 53, hasOption {
            if isAutorepeat { return nil }
            DispatchQueue.main.async { [self] in
                // …and "audibly" has to MEAN audibly. A read handed over a
                // quarter-second ago reports isSpeaking while it is still
                // dead silent, so a second press arriving in that window
                // took the stop branch and killed the read this very
                // button had just asked for — no syllable, no earcon, no
                // retry (the finish reads as a user stop, which is never
                // re-spoken). Whatever produced the second press — a
                // bounced switch on the read button, a repeat the HID
                // layer never flagged, an impatient thumb — the answer is
                // the same and it is not "silence": the read is already
                // on its way. Doing nothing is the whole fix; past the
                // grace window the press works normally again, so a
                // genuinely wedged synthesizer can still be stopped.
                if isReadStarting() {
                    fputs("[keyboard] read press ignored — the read is "
                        + "still starting\n", stderr)
                    return
                }
                if isSpeaking() {
                    let paused = isReadPaused()
                    onStop?("read button")
                    if paused {
                        Self.readSelection { [self] text in onSpeakDocument?(text, 0) }
                    }
                } else {
                    Self.readSelection { [self] text in onSpeakDocument?(text, 0) }
                }
            }
            return nil
        }

        // Ctrl+Option+M (keycode 46) — toggle Marduk on/off
        if keycode == 46, hasControl, hasOption, !hasCommand {
            if isAutorepeat { return nil }
            isEnabled.toggle()
            if isEnabled { mode = .normal }
            // Never carry tap/hold state across a toggle — a half-decided
            // Escape must not fire (or swallow a keyUp) after re-enable
            pendingEscapeHold?.cancel()
            pendingEscapeHold = nil
            pendingReadingEscape?.cancel()
            pendingReadingEscape = nil
            escapeHoldFired = false
            // Same for a half-decided typing burst: discard, don't flush
            discardBurstAndReplay()
            // And a half-typed ":" command
            commandBuffer = ""
            commandIdleTimer?.cancel()
            // And any read-motion state (a paused search must not eat keys
            // after re-enable; the daemon side resumes nothing — the read
            // itself was stopped by the toggle path or died with it)
            readSearchDirection = nil
            readSearchBuffer = ""
            resetReadMotionState()
            readingCapture = false
            // And any armed spoken question (releases its retained target)
            cancelQuestion()
            let state = isEnabled ? "ON (NORMAL)" : "OFF"
            fputs("[keyboard] Marduk \(state)\n", stderr)
            let word = isEnabled ? "Systems engaged" : "Systems disengaged"
            let on = isEnabled
            DispatchQueue.main.async { [self] in
                // Disabling mid-narration must not leave media stuck paused
                if narrationActive {
                    narrationActive = false
                    postKey(keycode: 45)
                    onNarrate?(false)
                }
                // And NEWS/STOCKS modes stand down with everything else
                if newsActive {
                    setNewsActive(false)
                    onNewsCommand?(.exit)
                }
                if stocksActive {
                    setStocksActive(false)
                    onStocksCommand?(.exit)
                }
                if toggleEarconEnabled {
                    if on { Earcon.bloopUp() } else { Earcon.bloopDown() }
                } else {
                    onAnnounce?(word)
                }
            }
            return nil
        }

        // === Interactive question (any mode except COMMAND) ===
        // While Marduk awaits an answer to a spoken question (dialog-focus
        // consent), the valid keys ARE the answer and Escape bails — no
        // mode ceremony, because a dialog interrupts whatever the user was
        // doing. This sits BEFORE every mode gate AND the typing-rescue
        // burst so the answer is taken instantly wherever they are — which
        // is also exactly what keeps a/o/n/s OUT of the dialog's own fields
        // (the field incident: o/n landed in a password username box).
        // Any other unmodified key means "not answering" — the question
        // evaporates and the key does its normal thing. Cmd/Ctrl/Option
        // combos skip this entirely (Cmd+C mid-question keeps the question;
        // the timeout bounds it). COMMAND is excluded: you're typing a
        // Marduk command (`:config …`), and a re-arming dialog eating its
        // a/o/s letters mangled the command (field 2026-07-22). Zero
        // effect when nothing is armed.
        if pendingQuestionAnswer != nil, mode != .command,
           !hasCommand, !hasControl, !hasOption {
            if let ch = Self.commandKeyChars[keycode], pendingQuestionKeys.contains(ch),
               !flags.contains(.maskShift) {
                if isAutorepeat { return nil }
                let respond = pendingQuestionAnswer
                cancelQuestion()
                fputs("[keyboard] question answered: \(ch)\n", stderr)
                DispatchQueue.main.async { respond?(ch) }
                return nil
            }
            if keycode == 53 {  // Escape — bail out of the question
                if isAutorepeat { return nil }
                cancelQuestion()
                fputs("[keyboard] question dismissed\n", stderr)
                DispatchQueue.main.async { Earcon.riseToNormal() }
                return nil
            }
            cancelQuestion()  // moved on — key falls through to normal
        }

        // === Marduk disabled: pass everything through ===
        guard isEnabled else { return pass }

        // READING-Escape rollover: another key while the reading Escape is
        // still withheld resolves it as a tap (pause), then the new key
        // takes its normal route — the pause dispatch lands on main before
        // any motion the key produces, so ordering holds (a fast Esc-then-(
        // pauses, then the jump's respeak resumes from the target).
        if pendingReadingEscape != nil, keycode != 53 {
            pendingReadingEscape?.cancel()
            pendingReadingEscape = nil
            DispatchQueue.main.async { [self] in onPauseToggle?() }
        }

        // Rollover: another key while a tapped Escape is still withheld means
        // the user typed on (fast Esc then j in vim). Letting this event pass
        // while the Escape is re-posted asynchronously would deliver them out
        // of order (vim would insert a stray "j"). Swallow it and re-post
        // both synthetically, in order. Pending state implies INSERT mode, so
        // this key was app-bound anyway (always-active shortcuts, which the
        // marker would bypass, were already handled above).
        if pendingEscapeHold != nil, keycode != 53 {
            pendingEscapeHold?.cancel()
            pendingEscapeHold = nil
            if let rolled = event.copy() {
                rolled.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
                DispatchQueue.main.async { [self] in
                    postKey(keycode: 53)
                    rolled.post(tap: .cghidEventTap)
                }
                return nil
            }
            // Copy failed: at least deliver the Escape, let this event pass
            DispatchQueue.main.async { [self] in postKey(keycode: 53) }
        }

        // Replay rollover: while a typing-rescue replay is queued but not
        // yet posted, letting a real key through would deliver it before
        // the replayed burst (fast "sho" would type "osh"). Swallow it and
        // append to the replay so everything lands in order. This window is
        // a single runloop turn right after the NORMAL→INSERT flip, so a
        // real Escape caught here is typed rather than tap/hold-detected —
        // acceptable. Flush redispatches manage their own ordering.
        if !replayQueue.isEmpty, !isFlushingBurst, let queued = event.copy() {
            enqueueReplay(queued)
            return nil
        }

        // === READ-SEARCH entry: typing a / or ? query over a paused read ===
        // A lightweight sibling of COMMAND mode. The read was paused on
        // entry; echo goes through the dedicated echo path (announce()
        // would stop() the paused read). MUST be checked before the Space
        // pause block: Space is a LITERAL query char here, and the paused
        // read still reports readActive — Space would otherwise resume it
        // mid-query.
        if let direction = readSearchDirection {
            // Read died under us (Option+Escape, daemon restart): abandon
            // the entry state and let the key take its normal route.
            if !isReadActive() {
                readSearchDirection = nil
                readSearchBuffer = ""
            } else {
                // Ctrl+O/Ctrl+I are OURS during a read (the jumplist), and
                // this block runs before the capture's carve-out. Letting
                // them through here sends Ctrl+O to the frontmost app —
                // in Terminal that is readline's operate-and-get-next,
                // which EXECUTES a shell history line the user never typed.
                if hasControl, !hasCommand, !hasOption, keycode == 31 || keycode == 34 {
                    DispatchQueue.main.async { Earcon.error() }
                    return nil
                }
                if hasCommand || hasControl { return pass }   // app shortcuts untouched
                if isAutorepeat, keycode != 51 { return nil } // only Delete repeats

                switch keycode {
                case 36: // Return — run the search (empty buffer = cancel)
                    let query = readSearchBuffer
                    readSearchDirection = nil
                    readSearchBuffer = ""
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        DispatchQueue.main.async { [self] in onReadSearchCancel?() }
                    } else {
                        lastReadAction = .search(query, direction)
                        // Length only — the query is user content and the
                        // log gets pasted into public issues
                        fputs("[keyboard] read search "
                            + "\(direction == .forward ? "/" : "?") "
                            + "(\(query.count) chars)\n", stderr)
                        DispatchQueue.main.async { [self] in
                            onReadSearch?(query, direction)
                        }
                    }
                    return nil

                case 53: // Escape — cancel, resume the read where it paused
                    readSearchDirection = nil
                    readSearchBuffer = ""
                    fputs("[keyboard] read search cancelled\n", stderr)
                    DispatchQueue.main.async { [self] in onReadSearchCancel?() }
                    return nil

                case 51: // Delete — edit; empty buffer backs out entirely
                    if let removed = readSearchBuffer.popLast() {
                        let spoken = removed == " " ? "space" : String(removed)
                        DispatchQueue.main.async { [self] in
                            if commandEchoEnabled { onReadSearchEcho?("\(spoken) deleted") }
                        }
                    } else {
                        readSearchDirection = nil
                        DispatchQueue.main.async { [self] in onReadSearchCancel?() }
                    }
                    return nil

                default:
                    if hasOption { return pass }  // zoom shortcuts ride on Option
                    if let ch = Self.commandKeyChars[keycode] {
                        readSearchBuffer.append(ch)
                        let spoken = ch == " " ? "space" : String(ch)
                        DispatchQueue.main.async { [self] in
                            if commandEchoEnabled { onReadSearchEcho?(spoken) }
                        }
                        return nil
                    }
                    if Self.typingPunctuationKeys.contains(keycode) {
                        DispatchQueue.main.async { Earcon.error() }
                        return nil
                    }
                    return pass  // F-keys, media keys — not query input
                }
            }
        }

        // === Space: pause/resume an active read (NORMAL/VISUAL only) ===
        // Only while a content read is speaking or paused — announcements
        // never capture Space, and otherwise it types/passes as normal.
        // INSERT means typing: Space is always a real space there, even
        // mid-read. A typing-rescue burst in flight means the user is
        // typing, so Space stays typing there too. Escape (NORMAL) cancels
        // a paused read — a paused synthesizer still counts as speaking —
        // which frees Space back to normal. isReadActive is plain stored
        // state on the speech engine, safe to read in the tap callback.
        if keycode == 49, mode != .insert, mode != .command,
           !hasCommand, !hasControl, !hasOption,
           !flags.contains(.maskShift), burstBuffer.isEmpty, isReadActive() {
            if isAutorepeat { return nil }
            DispatchQueue.main.async { [self] in onPauseToggle?() }
            return nil
        }

        // === READING capture (readmotions on): the read owns the keyboard ===
        // Engaged from ANY mode when a read starts (readStateChanged) —
        // reading is a real mode, not a NORMAL overlay: a read fired from
        // INSERT used to let ( and gg type straight over the selection.
        // b/w step words, (/) sentences, {/} paragraphs, digits build a
        // count (3( = back three), gg/G edges, . repeats, / and ? search,
        // Space pauses. i and Escape are the ONLY exits (both stop the
        // read); every other typing-shaped key buzzes instead of leaking
        // into the app. Cmd/Ctrl/Option combos and non-typing keys
        // (arrows, F-keys, media) still pass. Motions deliberately ALLOW
        // autorepeat — holding ( glides back sentence by sentence; the
        // engine recomputes from the live position each time. A typing
        // burst in flight predates the read — typing intent wins
        // (declareTyping drops the capture).
        if readingCapture, !isReadActive() {
            readingCapture = false  // engine state is the truth; heal drift
        }
        // Ctrl+F / Ctrl+B — vim page scroll, the capture-only exception to
        // the Ctrl-passthrough rule, and only here: during a captured read
        // the app receives no keys anyway, so the carve-out steals nothing.
        // Counts apply (3 Ctrl+F = three pages, vim semantics); autorepeat
        // allowed like the motions; buzzes via the daemon on unpaged
        // reads. Every other Ctrl combo still passes through everywhere.
        if readingCapture, hasControl, !hasCommand, !hasOption,
           burstBuffer.isEmpty, keycode == 3 || keycode == 11 {
            let count = max(1, readMotionCount)
            readMotionCount = 0
            let step = keycode == 3 ? count : -count
            lastReadAction = .pageStep(step)
            DispatchQueue.main.async { [self] in onReadPageStep?(step) }
            return nil
        }
        // Ctrl+G — vim's file-info: where am I? Same capture-only carve-
        // out as Ctrl+F/B. One-shot; consumes a pending count (count
        // Ctrl+G is vim's full-path variant — no audio meaning).
        // Ctrl+O / Ctrl+I — vim's jumplist: walk back through the places
        // jumps came from, and forward again. Autorepeat is deliberately
        // SUPPRESSED (unlike Ctrl+F/B): a cross-window restore rebuilds a
        // 45k window and re-fetches pronunciations synchronously on main,
        // right beside the event tap, so a held key is the same shape as
        // the stall the input cap exists to prevent.
        if readingCapture, hasControl, !hasCommand, !hasOption,
           burstBuffer.isEmpty, keycode == 31 || keycode == 34 {
            if isAutorepeat { return nil }
            let count = max(1, readMotionCount)
            // Ctrl+G leaves f/bracket arms set; clear everything so the
            // next key isn't eaten as a find target.
            resetReadMotionState()
            let direction: ReadDirection = keycode == 31 ? .back : .forward
            // Deliberately does NOT set lastReadAction — vim's `.` does not
            // repeat Ctrl+O.
            DispatchQueue.main.async { [self] in onReadJumpList?(direction, count) }
            return nil
        }

        if readingCapture, hasControl, !hasCommand, !hasOption,
           burstBuffer.isEmpty, keycode == 5 {
            if isAutorepeat { return nil }
            readMotionCount = 0
            pendingReadG = false
            DispatchQueue.main.async { [self] in onReadPosition?() }
            return nil
        }
        if readingCapture, !hasCommand, !hasControl, !hasOption,
           burstBuffer.isEmpty {
            let hasShift = flags.contains(.maskShift)

            // Armed f/F: the NEXT typing key is the find target — checked
            // first so any char works, even ones with motion meanings
            // (f-then-( finds a paren). Non-typing keys (Escape, arrows)
            // cancel silently and act normally, vim-style.
            if let direction = pendingReadFind {
                if isAutorepeat { return nil }
                pendingReadFind = nil
                if let ch = Self.commandKeyChars[keycode] {
                    // commandKeyChars is a-z 0-9 space: uppercased() is
                    // always a single scalar here
                    let target = hasShift ? Character(ch.uppercased()) : ch
                    lastReadAction = .find(target, direction)
                    DispatchQueue.main.async { [self] in
                        onReadFind?(target, direction)
                    }
                    return nil
                }
            }

            // Armed ] or [ — resolve the bracket pair: ]] next heading,
            // [[ previous, ][ next same-level sibling, [] previous
            // sibling, ]u parent (vim-markdown's header family). Any
            // other key clears the arm and falls through to its normal
            // meaning (]j degrades to a line motion, Escape still
            // pauses); shifted brackets never resolve — { } stay
            // paragraph motions.
            if let bracket = pendingReadBracket {
                if isAutorepeat { return nil }
                var motion: HeadingMotion?
                if !hasShift {
                    switch (bracket, keycode) {
                    case (.close, 30): motion = .next             // ]]
                    case (.open, 33):  motion = .previous         // [[
                    case (.close, 33): motion = .nextSibling      // ][
                    case (.open, 30):  motion = .previousSibling  // []
                    case (.close, 32): motion = .parent           // ]u
                    default: break
                    }
                }
                pendingReadBracket = nil
                if let motion {
                    let count = max(1, readMotionCount)
                    readMotionCount = 0
                    lastReadAction = .heading(motion, count)
                    DispatchQueue.main.async { [self] in
                        onReadHeading?(motion, count)
                    }
                    return nil
                }
            }

            if keycode == 3 { // f / F — arm char-find forward / back
                if isAutorepeat { return nil }
                readMotionCount = 0
                pendingReadG = false
                pendingReadFind = hasShift ? .back : .forward
                return nil
            }

            // ] or [ — arm the bracket pair. The pending count survives
            // arming (it precedes the pair: 2]]).
            if !hasShift, keycode == 30 || keycode == 33 {
                if isAutorepeat { return nil }
                pendingReadG = false
                pendingReadBracket = keycode == 30 ? .close : .open
                return nil
            }

            if keycode == 49, !flags.contains(.maskShift) { // Space — pause/resume
                if isAutorepeat { return nil }
                DispatchQueue.main.async { [self] in onPauseToggle?() }
                return nil
            }

            if keycode == 34 { // i — type WHILE the read keeps talking
                // (user-redesigned: the old exit also stopped the read, but
                // "take notes while listening" is a legitimate mode of
                // being human). The capture drops so keys reach the app;
                // the read plays on as background audio. Held Escape climbs
                // BACK into the capture (see the INSERT hold path); Option+
                // Escape stops the audio from anywhere.
                if isAutorepeat { return nil }
                if newsActive {
                    // No INSERT inside NEWS — typed keys would land in
                    // newsboat's TUI and silently desync the mirror.
                    // Leave news first (held Escape twice, or Escape from
                    // the list).
                    DispatchQueue.main.async { Earcon.error() }
                    return nil
                }
                readingCapture = false
                resetReadMotionState()
                mode = .insert
                suppressInsertEntryRepeat = true
                fputs("[keyboard] READING → INSERT (read continues)\n", stderr)
                DispatchQueue.main.async { Earcon.fallToInsert() }
                return nil
            }

            if keycode == 53 { // Escape — tap pauses/resumes, hold exits
                if isAutorepeat { return nil }
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.pendingReadingEscape = nil
                    guard self.readingCapture else { return }
                    self.escapeHoldFired = true
                    self.readingCapture = false
                    self.resetReadMotionState()
                    if self.newsActive {
                        // Held Escape during a news article climbs ONE
                        // level: stop the article, land on the news list
                        // (the daemon closes newsboat's pager via the
                        // read's completion) — Escape from the list then
                        // leaves news. riseToReading = "still captured",
                        // the INSERT-reclaim rung's sound.
                        fputs("[keyboard] READING escape held → news list\n",
                              stderr)
                        self.onStop?("escape held (news)")
                        Earcon.riseToReading()
                        return
                    }
                    self.mode = .normal
                    fputs("[keyboard] READING escape held → NORMAL\n", stderr)
                    self.onStop?("escape held")
                    Earcon.riseToNormal()
                }
                pendingReadingEscape?.cancel() // never stack two
                pendingReadingEscape = work
                DispatchQueue.main.asyncAfter(deadline: .now() + escapeHoldThreshold,
                                              execute: work)
                return nil
            }

            if keycode == 44 { // / or ? — search entry
                if isAutorepeat { return nil }
                readSearchDirection = hasShift ? .back : .forward
                readSearchBuffer = ""
                resetReadMotionState()
                fputs("[keyboard] read search entry (\(hasShift ? "?" : "/"))\n", stderr)
                let word = hasShift ? "search back" : "search"
                DispatchQueue.main.async { [self] in
                    onReadSearchBegin?()
                    if commandEchoEnabled { onReadSearchEcho?(word) }
                }
                return nil
            }

            // gg — back to the very beginning; G — the last paragraph
            // (vim's first/last line, scaled to listening). A lone g arms
            // the pair, vim-style with no timeout; any other key breaks it.
            if keycode == 5 {
                if isAutorepeat { return nil }
                if hasShift { // G — end of the read; with a count, page N (12G)
                    pendingReadG = false
                    let count = readMotionCount
                    readMotionCount = 0
                    if count > 0 {
                        DispatchQueue.main.async { [self] in onReadPageAbsolute?(count) }
                    } else {
                        lastReadAction = .edge(.forward)
                        DispatchQueue.main.async { [self] in onReadJumpEdge?(.forward) }
                    }
                } else if pendingReadG { // gg
                    pendingReadG = false
                    readMotionCount = 0
                    lastReadAction = .edge(.back)
                    DispatchQueue.main.async { [self] in onReadJumpEdge?(.back) }
                } else {
                    pendingReadG = true
                }
                return nil
            }
            pendingReadG = false  // any non-g key breaks a pending gg

            // r — abandon this read and read what's under the pointer
            // instead; R — abandon it and read the focused document from
            // the caret to the end (both work speaking or paused; the
            // replacement read keeps media ducked and the capture engaged)
            if keycode == 15 {
                if isAutorepeat { return nil }
                readMotionCount = 0
                if hasShift {
                    fputs("[keyboard] READING R → document read\n", stderr)
                    readDocumentFromCaret()
                } else {
                    fputs("[keyboard] READING r → new read\n", stderr)
                    readAtPointer()
                }
                return nil
            }

            // z / Z — spell the current word / sentence over the paused
            // read (vim's own spell commands live under z). A second z on
            // the same word within a few seconds spells it phonetically —
            // Charlie, Alpha, Tango.
            if keycode == 6 {
                if isAutorepeat { return nil }
                readMotionCount = 0
                let unit: ReadUnit = hasShift ? .sentence : .word
                DispatchQueue.main.async { [self] in onReadSpell?(unit) }
                return nil
            }

            // Digits accumulate a count. Bare 0 never starts one (vim: 0
            // is a motion, not a count starter) — it only joins after 3,
            // 30…; on its own it restarts the current line below.
            if !hasShift, let digit = Self.digitKeyCodes[keycode],
               digit != 0 || readMotionCount > 0 {
                readMotionCount = min(readMotionCount * 10 + digit, 999)
                return nil
            }

            // Bare 0 — vim line start: restart the current line
            if !hasShift, keycode == 29 {
                DispatchQueue.main.async { [self] in onReadLineStart?() }
                return nil
            }

            // {count}% — vim percent-of-file navigation: 50% respeaks
            // from halfway through the document. Bare % stays vim-honest
            // (match-paren has no audio meaning) and buzzes.
            if hasShift, keycode == 23 {
                if isAutorepeat { return nil }
                let count = readMotionCount
                readMotionCount = 0
                if count > 0 {
                    DispatchQueue.main.async { [self] in onReadPercent?(count) }
                } else {
                    DispatchQueue.main.async { Earcon.error() }
                }
                return nil
            }

            // . — repeat the last motion; a pending count overrides a
            // jump's recorded one (3. = the same motion, three times).
            // Autorepeat allowed: holding . keeps stepping, like the
            // motions themselves.
            if keycode == 47, !hasShift {
                guard let action = lastReadAction else {
                    readMotionCount = 0
                    DispatchQueue.main.async { Earcon.error() }
                    return nil
                }
                let pending = readMotionCount
                readMotionCount = 0
                switch action {
                case .jump(let unit, let direction, let recorded):
                    let n = pending > 0 ? pending : recorded
                    lastReadAction = .jump(unit, direction, n)
                    DispatchQueue.main.async { [self] in onReadJump?(unit, direction, n) }
                case .edge(let direction):
                    DispatchQueue.main.async { [self] in onReadJumpEdge?(direction) }
                case .search(let query, let direction):
                    DispatchQueue.main.async { [self] in onReadSearch?(query, direction) }
                case .find(let char, let direction):
                    DispatchQueue.main.async { [self] in onReadFind?(char, direction) }
                case .pageStep(let step):
                    DispatchQueue.main.async { [self] in onReadPageStep?(step) }
                case .heading(let motion, let recorded):
                    let n = pending > 0 ? pending : recorded
                    lastReadAction = .heading(motion, n)
                    DispatchQueue.main.async { [self] in onReadHeading?(motion, n) }
                }
                return nil
            }

            var jump: (ReadUnit, ReadDirection)?
            if hasShift {
                switch keycode {
                case 25: jump = (.sentence, .back)     // (
                case 29: jump = (.sentence, .forward)  // )
                case 33: jump = (.paragraph, .back)    // {
                case 30: jump = (.paragraph, .forward) // }
                default: break
                }
            } else {
                switch keycode {
                case 11: jump = (.word, .back)         // b
                case 13: jump = (.word, .forward)      // w
                case 4:  jump = (.word, .back)         // h — hjkl cluster:
                case 37: jump = (.word, .forward)      // l   h/l word,
                case 38: jump = (.line, .forward)      // j   j/k line
                case 40: jump = (.line, .back)         // k
                default: break
                }
            }
            if let (unit, direction) = jump {
                let count = max(1, readMotionCount)
                readMotionCount = 0
                lastReadAction = .jump(unit, direction, count)
                DispatchQueue.main.async { [self] in
                    onReadJump?(unit, direction, count)
                }
                return nil
            }
            // Everything else typing-shaped buzzes — reading owns the
            // keyboard, and a silently swallowed key would read as a dead
            // keyboard. Covers letters, shifted digits, punctuation,
            // Return, Tab, Delete. Non-typing keys — arrows, F-keys,
            // media, Naga button codes — pass through untouched.
            // Space (49) belongs here too: the pause branch above requires
            // an UNSHIFTED Space, so Shift+Space fell through this test and
            // returned `pass` — typing a space into the user's document
            // mid-read, which is exactly what this block exists to prevent.
            if Self.alphaKeyCodes.contains(keycode) || keycode == 40 // K
                || Self.digitKeyCodes[keycode] != nil
                || Self.typingPunctuationKeys.contains(keycode)
                || keycode == 36 || keycode == 48 || keycode == 51
                || keycode == 49 {
                readMotionCount = 0
                if !isAutorepeat {
                    DispatchQueue.main.async { Earcon.error() }
                }
                return nil
            }
            return pass
        }

        // === INSERT-mode n over a Firefox Reader document ===
        // The key PASSES THROUGH untouched — it IS Narrate's play/pause —
        // but Marduk reacts around it: duck + hold on start, release on
        // the next n. The AX context check runs async on main and only
        // matches focus inside an about:reader web area, so text boxes
        // and the URL bar keep typing their n's; mid-narration typing in
        // some other Firefox field stays typing too (end the handoff
        // from NORMAL, or with the n that stops Narrate in the reader).
        if mode == .insert, keycode == 45, !isAutorepeat, isFirefoxFrontmost,
           !hasOption, !flags.contains(.maskShift) {
            DispatchQueue.main.async { [self] in
                guard Self.narrationContext() else { return }
                narrationActive.toggle()
                fputs("[keyboard] narration \(narrationActive ? "handoff" : "off") (INSERT)\n", stderr)
                onNarrate?(narrationActive)
            }
            return pass
        }

        // === Option+Up/Down: live speech rate (opt-in, NORMAL/VISUAL) ===
        // No autorepeat guard on purpose — holding the key keeps nudging.
        // INSERT and COMMAND are excluded: apps own Option+arrows there
        // (editor move-line), and command mode arrows drive the palette.
        // Shift excluded too — Option+Shift+arrows is text selection.
        if speedKeysEnabled, keycode == 126 || keycode == 125,
           mode != .insert, mode != .command,
           hasOption, !hasCommand, !hasControl, !flags.contains(.maskShift) {
            let delta: Float = (keycode == 126 ? 10.0 : -10.0) / 360.0
            DispatchQueue.main.async { [self] in onRateChange?(delta) }
            return nil
        }

        // === NEWS search entry ("/" and "?"): type, Return jumps ===
        // A jump, not a filter — narrowing the mirror would desync every
        // posted arrow. Chars echo like the command line; Return hands the
        // query to the reader (smartcase, no wrap), Escape/empty cancels,
        // Delete edits and backs out on empty.
        if newsActive, newsSearchDirection != nil, mode == .normal,
           !readingCapture {
            if hasCommand || hasControl || hasOption { return pass }
            if isAutorepeat, keycode != 51 { return nil }
            let hasShift = flags.contains(.maskShift)
            switch keycode {
            case 36: // Return — search (empty = cancel)
                let query = newsSearchBuffer
                let direction = newsSearchDirection ?? .forward
                newsSearchDirection = nil
                newsSearchBuffer = ""
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    DispatchQueue.main.async { Earcon.riseToNormal() }
                } else {
                    fputs("[keyboard] news search (\(query.count) chars)\n", stderr)
                    DispatchQueue.main.async { [self] in
                        onNewsCommand?(.search(query, direction))
                    }
                }
                return nil
            case 53: // Escape — cancel back to the list
                newsSearchDirection = nil
                newsSearchBuffer = ""
                DispatchQueue.main.async { Earcon.riseToNormal() }
                return nil
            case 51: // Delete — edit; empty buffer backs out
                if newsSearchBuffer.popLast() == nil {
                    newsSearchDirection = nil
                    DispatchQueue.main.async { Earcon.riseToNormal() }
                }
                return nil
            default:
                if let ch = Self.commandKeyChars[keycode] {
                    // Shift capitalizes — capitals make the search
                    // case-sensitive (smartcase, the read-search rule)
                    let typed = hasShift ? Character(ch.uppercased()) : ch
                    newsSearchBuffer.append(typed)
                    let spoken = typed == " " ? "space" : String(typed)
                    DispatchQueue.main.async { [self] in
                        if commandEchoEnabled { onAnnounce?(spoken) }
                    }
                    return nil
                }
                if Self.typingPunctuationKeys.contains(keycode) || keycode == 48 {
                    DispatchQueue.main.async { Earcon.error() }
                    return nil
                }
                return pass
            }
        }

        // === NEWS mode: the newsboat list owns the keyboard ===
        // Armed by the daemon once the mirror is loaded; an article read
        // layers the READING capture ABOVE this block (it ran earlier), so
        // these keys are list navigation only. The tap consumes j/k etc.
        // and the NewsReader posts the equivalent arrows to newsboat —
        // never letting the raw key through, so mirror and TUI move as
        // one. Cmd/Ctrl/Option combos pass (zoom rides Option); ":" keeps
        // the command line reachable; other typing-shaped keys buzz
        // instead of leaking into the TUI (the READING-capture rule).
        if newsActive, mode == .normal, !readingCapture, burstBuffer.isEmpty {
            if hasCommand || hasControl || hasOption { return pass }
            let hasShift = flags.contains(.maskShift)

            if keycode == 41, hasShift { // ":" — command line, news stays armed
                if isAutorepeat { return nil }
                newsCount = 0
                pendingNewsG = false
                enterCommandMode()
                return nil
            }

            // Digits build a count, vim style (3j)
            if !hasShift, let digit = Self.digitKeyCodes[keycode],
               digit != 0 || newsCount > 0 {
                pendingNewsG = false
                newsCount = min(newsCount * 10 + digit, 999)
                return nil
            }

            if keycode == 5 { // g / G — top and bottom (gg arms, vim style)
                if isAutorepeat { return nil }
                newsCount = 0
                if hasShift {
                    pendingNewsG = false
                    DispatchQueue.main.async { [self] in onNewsCommand?(.bottom) }
                } else if pendingNewsG {
                    pendingNewsG = false
                    DispatchQueue.main.async { [self] in onNewsCommand?(.top) }
                } else {
                    pendingNewsG = true
                }
                return nil
            }
            if keycode == 2, !hasShift { // d (or dd) — delete the article.
                // Immediate on the FIRST press; a second d inside the
                // pair window is swallowed, so bare d and vim's dd both
                // delete exactly one (the uu-window idea, inverted).
                if isAutorepeat { return nil }
                newsCount = 0
                pendingNewsG = false
                guard Date().timeIntervalSince(lastNewsDelete) > 0.45 else {
                    return nil
                }
                lastNewsDelete = Date()
                DispatchQueue.main.async { [self] in
                    onNewsCommand?(.deleteArticle)
                }
                return nil
            }
            if keycode == 8, hasShift { // C — mark all read (newsboat's own C)
                if isAutorepeat { return nil }
                newsCount = 0
                pendingNewsG = false
                DispatchQueue.main.async { [self] in onNewsCommand?(.markAllRead) }
                return nil
            }
            pendingNewsG = false

            switch keycode {
            case 38, 125: // j / Down — next item (autorepeat glides)
                let count = max(1, newsCount)
                newsCount = 0
                DispatchQueue.main.async { [self] in onNewsCommand?(.move(count)) }
                return nil
            case 40, 126: // k / Up — previous item
                let count = max(1, newsCount)
                newsCount = 0
                DispatchQueue.main.async { [self] in onNewsCommand?(.move(-count)) }
                return nil
            case 36, 37: // Return / l — open
                if isAutorepeat { return nil }
                newsCount = 0
                DispatchQueue.main.async { [self] in onNewsCommand?(.open) }
                return nil
            case 4, 12: // h / q — back (q from the feed list quits newsboat)
                if isAutorepeat { return nil }
                newsCount = 0
                DispatchQueue.main.async { [self] in onNewsCommand?(.back) }
                return nil
            case 15: // r / R — read the article, full reading machinery
                if isAutorepeat { return nil }
                newsCount = 0
                DispatchQueue.main.async { [self] in onNewsCommand?(.read) }
                return nil
            case 31: // o — open in the browser (news stands down on the switch)
                if isAutorepeat { return nil }
                newsCount = 0
                DispatchQueue.main.async { [self] in onNewsCommand?(.openInBrowser) }
                return nil
            case 44: // "/" forward, "?" (shift) backward — title search
                if isAutorepeat { return nil }
                newsCount = 0
                newsSearchDirection = hasShift ? .back : .forward
                newsSearchBuffer = ""
                DispatchQueue.main.async { [self] in
                    if commandEchoEnabled {
                        onAnnounce?(hasShift ? "search back" : "search")
                    }
                }
                return nil
            case 47: // "." — repeat the last search (vim's n; news n = exit)
                if isAutorepeat { return nil }
                DispatchQueue.main.async { [self] in
                    onNewsCommand?(.searchRepeat)
                }
                return nil
            case 16: // y — yank the link, vim style (yy just yanks again)
                if isAutorepeat { return nil }
                newsCount = 0
                DispatchQueue.main.async { [self] in onNewsCommand?(.copyLink) }
                return nil
            case 17: // t — triage: local-LLM top 3 + dedup
                if isAutorepeat { return nil }
                newsCount = 0
                DispatchQueue.main.async { [self] in onNewsCommand?(.triage) }
                return nil
            case 34: // i — drive newsboat RAW: keys pass through untouched
                     // (newsboat's own n/r/R reload bindings and everything
                     // else). Hold Escape to climb back to the news list;
                     // hold again from the list for NORMAL. The mirror
                     // can't see raw keystrokes — reclaim refreshes its
                     // data and re-speaks the row, but the TUI cursor may
                     // have moved (documented limit).
                if isAutorepeat { return nil }
                mode = .insert
                suppressInsertEntryRepeat = true
                fputs("[keyboard] news → INSERT (raw newsboat control)\n", stderr)
                DispatchQueue.main.async { [self] in
                    Earcon.fallToInsert()
                    onNewsCommand?(.rawControl)   // the key bar flips its text
                }
                return nil
            case 53, 45: // Escape / n — leave news (newsboat keeps running)
                if isAutorepeat { return nil }
                setNewsActive(false)
                fputs("[keyboard] news → NORMAL\n", stderr)
                DispatchQueue.main.async { [self] in
                    onNewsCommand?(.exit)
                    Earcon.riseToNormal()
                }
                return nil
            default:
                if Self.alphaKeyCodes.contains(keycode) || keycode == 40
                    || Self.digitKeyCodes[keycode] != nil
                    || Self.typingPunctuationKeys.contains(keycode)
                    || keycode == 48 || keycode == 51 || keycode == 49 {
                    newsCount = 0
                    if !isAutorepeat { DispatchQueue.main.async { Earcon.error() } }
                    return nil
                }
                return pass
            }
        }

        // === STOCKS mode: the watchlist owns the keyboard ===
        // Marduk-native — no external app, no key posting, just the
        // spoken cursor. a/b/s open a prefilled ":stock …" command line
        // (COMMAND mode takes over, then hands back here on Return).
        if stocksActive, mode == .normal, !readingCapture, burstBuffer.isEmpty {
            if hasCommand || hasControl || hasOption { return pass }
            let hasShift = flags.contains(.maskShift)

            if keycode == 41, hasShift { // ":" — command line, stocks stays armed
                if isAutorepeat { return nil }
                stocksCount = 0
                pendingStocksG = false
                enterCommandMode()
                return nil
            }

            if !hasShift, let digit = Self.digitKeyCodes[keycode],
               digit != 0 || stocksCount > 0 {
                pendingStocksG = false
                stocksCount = min(stocksCount * 10 + digit, 999)
                return nil
            }

            if keycode == 5 { // g / G — top and bottom
                if isAutorepeat { return nil }
                stocksCount = 0
                pendingStocksD = false
                if hasShift {
                    pendingStocksG = false
                    DispatchQueue.main.async { [self] in onStocksCommand?(.bottom) }
                } else if pendingStocksG {
                    pendingStocksG = false
                    DispatchQueue.main.async { [self] in onStocksCommand?(.top) }
                } else {
                    pendingStocksG = true
                }
                return nil
            }
            if keycode == 2, !hasShift { // d — dd removes the ticker, vim style
                if isAutorepeat { return nil }
                stocksCount = 0
                pendingStocksG = false
                if pendingStocksD {
                    pendingStocksD = false
                    DispatchQueue.main.async { [self] in onStocksCommand?(.remove) }
                } else {
                    pendingStocksD = true
                }
                return nil
            }
            pendingStocksG = false
            pendingStocksD = false

            switch keycode {
            case 38, 125: // j / Down
                let count = max(1, stocksCount)
                stocksCount = 0
                DispatchQueue.main.async { [self] in
                    onStocksCommand?(.move(count))
                }
                return nil
            case 40, 126: // k / Up
                let count = max(1, stocksCount)
                stocksCount = 0
                DispatchQueue.main.async { [self] in
                    onStocksCommand?(.move(-count))
                }
                return nil
            case 15, 36: // r / R / Return — speak the full quote
                if isAutorepeat { return nil }
                stocksCount = 0
                DispatchQueue.main.async { [self] in onStocksCommand?(.detail) }
                return nil
            case 0: // a — add a ticker (prefilled command line)
                if isAutorepeat { return nil }
                DispatchQueue.main.async { [self] in onStocksCommand?(.add) }
                return nil
            case 11: // b — buy alert for the current ticker
                if isAutorepeat { return nil }
                DispatchQueue.main.async { [self] in
                    onStocksCommand?(.buyTrigger)
                }
                return nil
            case 1 where !hasShift: // s — sell alert
                if isAutorepeat { return nil }
                DispatchQueue.main.async { [self] in
                    onStocksCommand?(.sellTrigger)
                }
                return nil
            case 44 where hasShift: // ? — speak the stocks keys
                if isAutorepeat { return nil }
                DispatchQueue.main.async { [self] in onStocksCommand?(.help) }
                return nil
            case 53, 12, 1: // Escape / q / S — leave stocks
                if isAutorepeat { return nil }
                setStocksActive(false)
                fputs("[keyboard] stocks → NORMAL\n", stderr)
                DispatchQueue.main.async { [self] in
                    onStocksCommand?(.exit)
                    Earcon.riseToNormal()
                }
                return nil
            default:
                if Self.alphaKeyCodes.contains(keycode) || keycode == 40
                    || Self.digitKeyCodes[keycode] != nil
                    || Self.typingPunctuationKeys.contains(keycode)
                    || keycode == 48 || keycode == 51 || keycode == 49 {
                    stocksCount = 0
                    if !isAutorepeat { DispatchQueue.main.async { Earcon.error() } }
                    return nil
                }
                return pass
            }
        }

        // === COMMAND mode: ":" line editor, driven entirely by the tap ===
        // The palette panel (if enabled) is display-only — it renders this
        // buffer; no window ever takes focus. Echo goes through onAnnounce.
        if mode == .command {
            // Ctrl+N / Ctrl+P — vim's completion-menu next/previous,
            // synonyms for Down/Up. The second Ctrl carve-out (after
            // reading's Ctrl+F/B), COMMAND-only: the user is driving
            // Marduk's command line, and passing these through would move
            // the app's cursor (macOS emacs bindings) mid-command anyway.
            // Autorepeat allowed, like the arrows.
            if hasControl, !hasCommand, !hasOption,
               keycode == 45 || keycode == 35 {
                let delta = keycode == 45 ? 1 : -1  // n down, p up
                DispatchQueue.main.async { [self] in onCommandSelect?(delta) }
                return nil
            }
            if hasCommand || hasControl { return pass }   // app shortcuts untouched
            if isAutorepeat, keycode != 51, keycode != 125, keycode != 126 {
                return nil                                 // only Delete/arrows repeat
            }

            switch keycode {
            case 36: // Return — submit (empty buffer = cancel)
                let cmd = commandBuffer
                if ColonCommand.staysOpenOnReturn(cmd) {
                    // Fuzzy search and every staged picker: Enter accepts
                    // the selection. Stay in COMMAND mode — the daemon
                    // either executes (and ends the mode) or expands the
                    // buffer for further typing. The set of pickers lives
                    // in ColonCommand, so adding one never edits the tap.
                    fputs("[keyboard] : \(cmd) (selection accept)\n", stderr)
                    DispatchQueue.main.async { [self] in onCommandSubmit?(cmd) }
                    return nil
                }
                commandBuffer = ""
                commandAbsorbTail = []
                commandIdleTimer?.cancel()
                mode = .normal
                if cmd.trimmingCharacters(in: .whitespaces).isEmpty {
                    DispatchQueue.main.async { Earcon.riseToNormal() }
                } else {
                    fputs("[keyboard] : \(cmd)\n", stderr)
                    DispatchQueue.main.async { [self] in onCommandSubmit?(cmd) }
                }
                return nil

            case 53: // Escape — cancel
                commandBuffer = ""
                commandAbsorbTail = []
                commandIdleTimer?.cancel()
                mode = .normal
                fputs("[keyboard] command cancelled → NORMAL\n", stderr)
                DispatchQueue.main.async { Earcon.riseToNormal() }
                return nil

            case 51: // Delete — edit; on an empty buffer, back out entirely
                commandAbsorbTail = []
                if let removed = commandBuffer.popLast() {
                    let buffer = commandBuffer
                    scheduleCommandIdle()
                    let spoken = removed == " " ? "space" : String(removed)
                    DispatchQueue.main.async { [self] in
                        if commandEchoEnabled { onAnnounce?("\(spoken) deleted") }
                        onCommandChange?(buffer, false)
                    }
                } else {
                    commandIdleTimer?.cancel()
                    mode = .normal
                    DispatchQueue.main.async { Earcon.riseToNormal() }
                }
                return nil

            case 48: // Tab — autocomplete to the palette's selected candidate
                scheduleCommandIdle()
                DispatchQueue.main.async { [self] in onCommandTab?() }
                return nil

            case 126, 125: // Up/Down — move the palette selection
                let delta = keycode == 126 ? -1 : 1
                DispatchQueue.main.async { [self] in onCommandSelect?(delta) }
                return nil

            case 44 where flags.contains(.maskShift): // "?" — speak options now
                DispatchQueue.main.async { [self] in onCommandHelp?() }
                return nil

            case 44: // "/" on an empty buffer — fuzzy search over everything
                if commandBuffer.isEmpty {
                    commandBuffer = "/"
                    scheduleCommandIdle()
                    DispatchQueue.main.async { [self] in
                        if commandEchoEnabled { onAnnounce?("search") }
                        onCommandChange?("/", false)
                    }
                } else {
                    DispatchQueue.main.async { Earcon.error() }
                }
                return nil

            default:
                // Option combos are system/app shortcuts (the user's zoom
                // keys ride on Option) — never command input. Pass them.
                if hasOption { return pass }
                if let ch = Self.commandKeyChars[keycode] {
                    // Absorb the tail of a word the auto-expand already
                    // completed; a mismatch ends the absorption.
                    if let expected = commandAbsorbTail.first, ch == expected {
                        commandAbsorbTail.removeFirst()
                        scheduleCommandIdle()
                        return nil
                    }
                    commandAbsorbTail = []
                    // Collapse double spaces (slow typing after an expansion)
                    if ch == " ", commandBuffer.hasSuffix(" ") { return nil }
                    commandBuffer.append(ch)
                    let buffer = commandBuffer
                    scheduleCommandIdle()
                    let spoken = ch == " " ? "space" : String(ch)
                    DispatchQueue.main.async { [self] in
                        if commandEchoEnabled { onAnnounce?(spoken) }
                        onCommandChange?(buffer, true)
                    }
                    return nil
                }
                // Typing-shaped keys (punctuation) buzz — they'd otherwise
                // leak into the app mid-command. Anything else (F-keys,
                // keypad, media keys, zoom shortcuts on custom codes)
                // passes through untouched.
                if Self.typingPunctuationKeys.contains(keycode) {
                    fputs("[keyboard] command mode rejected keycode \(keycode)\n", stderr)
                    DispatchQueue.main.async { Earcon.error() }
                    return nil
                }
                return pass
            }
        }

        // === INSERT mode: only intercept bare Escape (tap/hold) ===
        if mode == .insert {
            if keycode == 53 {
                // Modified Escape (Cmd/Ctrl/Shift) is an app shortcut — pass.
                // Option+Escape was already handled above.
                if hasCommand || hasControl || flags.contains(.maskShift) {
                    return pass
                }
                // Withhold the press until tap-vs-hold is decided. Autorepeats
                // must not leak into the app meanwhile.
                if isAutorepeat { return nil }
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.pendingEscapeHold = nil
                    self.escapeHoldFired = true
                    // Leave typing — and when a read is still playing, the
                    // read reclaims the keyboard first: hold Escape climbs
                    // INSERT → READING → NORMAL, one level per hold.
                    // The rung is chosen by the pure ModePolicy.
                    switch ModePolicy.escapeHoldDestination(
                        mode: .insert, readActive: self.isReadActive(),
                        readMotionsEnabled: self.readMotionsEnabled,
                        enabled: self.isEnabled
                    ) {
                    case .reclaimReading:
                        // Drop the underlying mode too: the user asked to
                        // leave INSERT. A natural read end only drops the
                        // capture, so leaving `.insert` here would silently
                        // return them to typing when the read finished.
                        self.mode = ModePolicy.underlyingMode(after: .reclaimReading,
                                                              current: self.mode)
                        self.readingCapture = true
                        fputs("[keyboard] escape held → READING (read reclaimed)\n",
                              stderr)
                        Earcon.riseToReading()  // middle rung — ends lower than NORMAL
                        return
                    case .normal, .passToApp:
                        self.mode = .normal
                        if self.newsActive {
                            // INSERT entered FROM news mode (raw newsboat
                            // control): the hold climbs back to the news
                            // list, not all the way out — Escape from the
                            // list is the next rung up to NORMAL. Same
                            // middle-rung sound as the reading reclaim.
                            fputs("[keyboard] escape held → NEWS (reclaimed)\n",
                                  stderr)
                            Earcon.riseToReading()
                            DispatchQueue.main.async { [weak self] in
                                self?.onNewsCommand?(.reclaim)
                            }
                            return
                        }
                        fputs("[keyboard] escape held → NORMAL\n", stderr)
                        Earcon.riseToNormal()
                    }
                }
                pendingEscapeHold?.cancel() // shouldn't happen, but never stack two
                pendingEscapeHold = work
                DispatchQueue.main.asyncAfter(deadline: .now() + escapeHoldThreshold, execute: work)
                return nil
            }
            // Swallow autorepeats of the `i` press that entered INSERT —
            // holding i would otherwise type "iii…" once the mode flips.
            // Any fresh (non-repeat) keypress ends the suppression, so a
            // deliberate held `i` typed later still repeats normally.
            if isAutorepeat, keycode == 34, suppressInsertEntryRepeat {
                return nil
            }
            suppressInsertEntryRepeat = false
            // Optional typing echo (classic screen-reader behavior, off by
            // default): speak the key, never consume it.
            if typingEchoEnabled, !isAutorepeat, !hasCommand, !hasControl, !hasOption,
               let ch = Self.commandKeyChars[keycode] {
                let spoken = ch == " " ? "space" : String(ch)
                DispatchQueue.main.async { [self] in onAnnounce?(spoken) }
            }
            return pass
        }

        // === VISUAL modes: hjkl extends selection, r reads, Escape exits ===
        // All AX/CGEvent work is dispatched off the tap callback: AX calls are
        // synchronous IPC to the target app (up to seconds if it's busy), and
        // a slow callback gets the tap disabled by macOS — which leaks
        // suppressed keys straight into the app. Main-queue ordering keeps the
        // dispatched blocks in keypress order.
        if mode == .visual || mode == .visualLine {
            if hasCommand || hasControl { return pass }

            // Exit/read are one-shot: a held key's autorepeat must not
            // re-trigger them. Motions (hjkl, G, digits) may repeat.
            if isAutorepeat, keycode == 53 || keycode == 9 || keycode == 15 {
                return nil
            }

            switch keycode {
            case 53, 9: // Escape or v/V — exit visual mode, collapse selection
                mode = .normal
                pendingCount = 0
                DispatchQueue.main.async { [self] in
                    collapseVisualSelection()
                    // Audible exit — the rising sweep that always means
                    // "back in NORMAL". (`r` skips it: the read that follows
                    // is its own feedback.)
                    Earcon.riseToNormal()
                }
                fputs("[keyboard] → NORMAL\n", stderr)
                return nil

            case 15: // r — read selection, exit to normal
                mode = .normal
                pendingCount = 0
                DispatchQueue.main.async { [self] in
                    visualAXState = nil
                    Self.readSelection { [self] text in onSpeakDocument?(text, 0) }
                }
                return nil

            case 4: // h — extend selection left
                extendSelection(.left, arrowKeycode: 123)
                return nil

            case 38: // j — extend selection down
                extendSelection(.down, arrowKeycode: 125)
                return nil

            case 40: // k — extend selection up
                extendSelection(.up, arrowKeycode: 126)
                return nil

            case 37: // l — extend selection right
                extendSelection(.right, arrowKeycode: 124)
                return nil

            case 5 where flags.contains(.maskShift): // G — select to end of text
                pendingCount = 0
                visualDidExtendSelection = true
                DispatchQueue.main.async { [self] in
                    if visualAXState != nil {
                        axMotion(.toEnd, count: 1)
                    } else {
                        postKey(keycode: 125, shift: true, command: true)
                    }
                }
                return nil

            default:
                if let digit = Self.digitKeyCodes[keycode] {
                    pendingCount = pendingCount * 10 + digit
                    return nil
                }
                return nil // suppress everything else
            }
        }

        // === NORMAL mode ===

        // Always pass through Cmd, Ctrl, and Option combos (system and app
        // shortcuts like Cmd+C — and the user's zoom keys, which ride on
        // Option). Option was missing here while COMMAND mode passed it
        // through deliberately for exactly that reason, so Option+r,
        // Option+s and friends fired Marduk's bare command in NORMAL and
        // never reached the app. Speed keys (Option+Up/Down) are handled
        // earlier, so they still work.
        if hasCommand || hasControl || hasOption {
            return pass
        }

        // Typing-burst rescue: letters are withheld briefly to tell fast
        // typing (→ INSERT + replay) from deliberate commands. Flush
        // redispatches re-enter handleEvent and must reach the real
        // command dispatch below, hence the isFlushingBurst bypass.
        if typingRescueEnabled, !isFlushingBurst,
           let verdict = burstIntercept(event: event, keycode: keycode, isAutorepeat: isAutorepeat) {
            switch verdict {
            case .swallow: return nil
            case .pass(let result): return result
            }
        }

        // One-shot commands must not re-fire on key autorepeat: a held `i`
        // would otherwise type "iii" after entering INSERT, a held `s` would
        // toggle speak-under-pointer repeatedly, a held `u` would launch
        // multiple updates, and a held Escape/`r` would restart or stop reads.
        if isAutorepeat, Self.oneShotNormalKeys.contains(keycode) {
            return nil
        }

        switch keycode {
        case 34: // i — enter INSERT mode
            mode = .insert
            suppressInsertEntryRepeat = true
            fputs("[keyboard] → INSERT\n", stderr)
            // Same falling sweep as the typing rescue — INSERT entry always
            // sounds the same, however you got there.
            DispatchQueue.main.async { Earcon.fallToInsert() }
            return nil

        case 32: // u — check for updates + speak what's new. uu (burst) or a
                 // second u while the check is armed actually installs — the
                 // daemon owns that decision.
            DispatchQueue.main.async { [self] in
                fputs("[keyboard] u → update check\n", stderr)
                onUpdateCheck?()
            }
            return nil

        case 9: // v — visual mode; V (shift) — visual line mode
            pendingCount = 0
            let lineMode = flags.contains(.maskShift)
            mode = lineMode ? .visualLine : .visual
            visualDidExtendSelection = lineMode // line mode selects on entry
            // AX state creation is synchronous IPC — keep it off the tap callback
            DispatchQueue.main.async { [self] in
                visualAXState = Self.tryCreateVisualAXState()
                let axTag = visualAXState != nil ? " (AX)" : ""
                if lineMode {
                    if visualAXState != nil {
                        axSelectCurrentLine()
                    } else {
                        postKey(keycode: 123, command: true)
                        postKey(keycode: 125, shift: true)
                    }
                    fputs("[keyboard] → VISUAL LINE\(axTag)\n", stderr)
                    onAnnounce?("visual line")
                } else {
                    fputs("[keyboard] → VISUAL\(axTag)\n", stderr)
                    onAnnounce?("visual")
                }
            }
            return nil

        case 15 where flags.contains(.maskShift): // R — read document from caret
            readDocumentFromCaret()
            return nil

        case 15: // r — read line (triple-click + speak)
            readAtPointer()
            return nil

        case 17: // t — speak time. tt (time + date) resolves in the burst
                 // layer, whose decision window replaces the old double-tap
                 // timer: a lone t reaches here on burst-timer expiry.
                 // (With typingRescue disabled there is no tt — each t
                 // speaks the time immediately.)
            DispatchQueue.main.async { [self] in
                onAnnounce?(Self.currentTime())
            }
            return nil

        case 1 where flags.contains(.maskShift) && stocksExtensionEnabled:
            // S — the stocks watchlist (unshifted s keeps hover speech;
            // with the extension off, S falls through to hover exactly as
            // it always did — zero new surface)
            DispatchQueue.main.async { [self] in onStocksOpen?() }
            return nil

        case 1: // s — toggle Marduk's own pointer hover speech (HoverSpeech:
                // the reading voice, rate, and pitch — the macOS hover
                // feature and its shortcut setup are no longer involved)
            DispatchQueue.main.async { [self] in onHoverToggle?() }
            return nil

        case 2 where flags.contains(.maskShift) && describeExtensionEnabled:
                 // D — describe the image under the pointer. Rides the
                 // same burst path as d (alpha keycodes enter the buffer
                 // shifted or not; 2 isn't a command letter, so a lone D
                 // lands here on burst expiry and D inside a word still
                 // rescues to typing). Extension off → D falls to the
                 // brief case below, as it did before the extension.
            DispatchQueue.main.async { [self] in onDescribe?() }
            return nil

        case 2 where briefExtensionEnabled: // d — speak the daily brief
                 // Reaches here only on burst expiry (a lone d), so `dd`
                 // on a source install still cuts a release and double-d
                 // words still rescue to typing. Extension off → the plain
                 // NORMAL buzz d has always been.
            DispatchQueue.main.async { [self] in onBriefOpen?() }
            return nil

        case 45 where isFirefoxFrontmost: // n — Firefox Reader narration handoff
            // Marduk steps aside for Firefox's own Narrate: stop our
            // speech, pause media and HOLD it paused, then hand the n to
            // Firefox (Narrate treats n as play/pause). Second n (or
            // Escape) pauses narration and releases the media. Outside
            // Firefox, n stays a plain letter (falls to the default beep,
            // and typing rescue still treats words like "sun" as typing).
            DispatchQueue.main.async { [self] in
                if narrationActive {
                    // Always allowed to end the handoff, wherever focus is
                    narrationActive = false
                    fputs("[keyboard] narration off — releasing media\n", stderr)
                    postKey(keycode: 45)
                    onNarrate?(false)
                    return
                }
                // The cache said Firefox — confirm against reality before
                // the Narrate gate eats the key. A stale cache here buzzed
                // n instead of opening news (field 2026-08-05).
                guard resyncFrontmost() == "org.mozilla.firefox" else {
                    fputs("[keyboard] n — stale Firefox cache, rerouting\n",
                          stderr)
                    if newsExtensionEnabled { onNewsOpen?() }
                    else { Earcon.error() }
                    return
                }
                // Only start when focus is inside a Reader document —
                // on a normal page n would pause media for nothing
                guard Self.narrationContext() else {
                    Earcon.error()
                    return
                }
                startNarrationHandoff()
            }
            return nil

        case 45 where newsExtensionEnabled: // n — open the news reader
                 // (newsboat handoff; extension off → the plain buzz). Reaches
                 // here only OUTSIDE Firefox (Narrate owns n there) and
                 // after the typing-rescue burst window, exactly like
                 // s/t/u: a lone n redispatches on burst expiry, while n
                 // inside a word ("runs", "sun") still rescues to typing —
                 // n stays out of BurstPolicy's command letters on purpose.
            DispatchQueue.main.async { [self] in
                // Symmetric staleness check: really in Firefox → n is
                // Narrate's key, not news. A phantom handoff left over
                // from a mid-narration app switch releases its media hold
                // first — news entry must never inherit a stuck hold.
                if resyncFrontmost() == "org.mozilla.firefox" {
                    fputs("[keyboard] n — stale front cache, Firefox is front\n",
                          stderr)
                    if narrationActive {
                        narrationActive = false
                        postKey(keycode: 45)
                        onNarrate?(false)
                    } else if Self.narrationContext() {
                        startNarrationHandoff()
                    } else {
                        Earcon.error()
                    }
                    return
                }
                if narrationActive {
                    // Narration abandoned by an app switch — release the
                    // duck hold so reads/news can unduck normally again
                    narrationActive = false
                    onNarrate?(false)
                }
                onNewsOpen?()
            }
            return nil

        case 28 where isFirefoxFrontmost: // 8 — Reader mode + narration, one key
            // Post Firefox's reader toggle (Cmd+Option+R), wait for the
            // Reader document to exist, then run the narration handoff.
            // Already narrating: full round trip — stop, release media,
            // close Reader. Digits normally pass through in NORMAL; this
            // is the one exception, Firefox-frontmost only.
            if flags.contains(.maskShift) || hasOption { return pass }
            if isAutorepeat { return nil }
            DispatchQueue.main.async { [self] in
                // Same staleness guard as n, with higher stakes: a stale
                // Firefox reading would post Cmd+Option+R into whatever
                // app is really front. Replay the digit instead — 8
                // passes through in NORMAL everywhere but Firefox. A
                // phantom handoff still releases its media hold (safe
                // anywhere); only the key posts need Firefox front.
                guard resyncFrontmost() == "org.mozilla.firefox" else {
                    fputs("[keyboard] 8 — stale Firefox cache, replaying digit\n",
                          stderr)
                    if narrationActive {
                        narrationActive = false
                        onNarrate?(false)
                    }
                    postKey(keycode: 28)
                    return
                }
                if narrationActive {
                    narrationActive = false
                    fputs("[keyboard] 8 — narration off, closing reader\n", stderr)
                    onNarrate?(false)
                    postKey(keycode: 15, command: true, option: true)
                } else if Self.narrationContext() {
                    // Reader already open — just start narrating
                    startNarrationHandoff()
                } else {
                    fputs("[keyboard] 8 — opening reader mode\n", stderr)
                    postKey(keycode: 15, command: true, option: true)
                    pollForReader(attempt: 0)
                }
            }
            return nil

        case 53: // Escape — stop speech if speaking; end a narration handoff
            DispatchQueue.main.async { [self] in
                if narrationActive {
                    narrationActive = false
                    fputs("[keyboard] narration off (Escape) — releasing media\n", stderr)
                    postKey(keycode: 45)
                    onNarrate?(false)
                }
                if isSpeaking() { onStop?("escape") }
            }
            return nil

        case 41 where flags.contains(.maskShift): // ":" — enter COMMAND mode
            if isAutorepeat { return nil }
            enterCommandMode()
            return nil

        default:
            // Suppress only letter keys to prevent typing. Pass through space,
            // numbers, function keys, arrows, mouse button keycodes (Naga), and
            // everything else. Space (49) and k (40) intentionally bleed through
            // so they take their normal effect (e.g. page scroll).
            if Self.alphaKeyCodes.contains(keycode) {
                // Non-command letter key in NORMAL mode: it does nothing (and is
                // suppressed so it isn't typed). Beep so the user notices they're
                // in NORMAL mode and may want INSERT. The first few buzzes EVER
                // (Self.buzzHintLimit, counted across restarts) also point at the
                // command panel — new users hit this constantly without knowing
                // what the buzzer means; after that the buzz stands alone.
                let explain = buzzHintsSpoken < Self.buzzHintLimit
                if explain { buzzHintsSpoken += 1 }
                let spoken = buzzHintsSpoken
                DispatchQueue.main.async { [self] in
                    Earcon.error()
                    if explain {
                        OnceMarker.setCount(Self.buzzHintMarker, spoken)
                        // Fixed-length earcon (~0.11s), not speech — the
                        // stagger just keeps the buzz audible before speech.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
                            onAnnounce?("Press colon, shift semicolon, to open "
                                + "the command panel and see every option.")
                        }
                    }
                }
                return nil
            }
            return pass
        }
    }

    /// ":" — shared by NORMAL and NEWS mode (a :config tweak must stay
    /// reachable mid-news; command Return/Escape land back where the ":"
    /// was pressed, because NEWS rides beside `mode`, not inside it).
    private func enterCommandMode() {
        mode = .command
        commandBuffer = ""
        commandAbsorbTail = []
        scheduleCommandIdle()
        fputs("[keyboard] → COMMAND\n", stderr)
        DispatchQueue.main.async { [self] in
            if commandEchoEnabled { onAnnounce?("command") }
            onCommandChange?("", false)
        }
    }

    /// Read started/ended (the engine's readActive didSet, via the daemon).
    /// Main-thread only, synchronous with speak()/the delegate callbacks, so
    /// the tap can never see an active read without its capture. Entry only
    /// when read motions are on and the keyboard is ours; COMMAND keeps its
    /// line editor (confirmation reads right after a : command must not
    /// steal the palette's keys). Natural end just drops the capture — the
    /// underlying mode was never changed, so the user lands back exactly
    /// where they were (INSERT stays INSERT).
    func readStateChanged(_ active: Bool) {
        if active {
            guard readMotionsEnabled, isEnabled, mode != .command,
                  !readingCapture else { return }
            readingCapture = true
            fputs("[keyboard] → READING\n", stderr)
        } else if readingCapture {
            readingCapture = false
            resetReadMotionState()
            // A withheld Escape must not fire its hold on a dead read; its
            // trailing keyUp passes as an orphan, which apps ignore
            pendingReadingEscape?.cancel()
            pendingReadingEscape = nil
            // Hundreds of AXUIElement refs into a browser process must die
            // with the read, not linger until the next one
            clearWebReadAnchors()
            // ...and so must the accessibility flags the harvest set on the
            // app: anchors need them alive for scroll-follow, nothing does
            // afterwards, and an app left in full-accessibility mode for
            // days is a slow machine (AXNudge)
            AXNudge.shared.restoreAll(reason: "read ended")
            fputs("[keyboard] read ended → \(mode)\n", stderr)
        } else {
            clearWebReadAnchors()  // reads without capture (motions off) too
            AXNudge.shared.restoreAll(reason: "read ended")
        }
    }

    /// Replaces the COMMAND-mode buffer (Tab autocomplete). Main-thread only,
    /// same as every other piece of tap state; re-fires onCommandChange so
    /// the palette re-renders.
    func replaceCommandBuffer(_ text: String, absorbing: String = "") {
        guard mode == .command else { return }
        commandBuffer = text
        commandAbsorbTail = Array(absorbing)
        scheduleCommandIdle()
        onCommandChange?(text, true)
    }

    /// Ends COMMAND mode from the daemon side — the auto-accept path, where
    /// an unambiguous buffer executes without Enter. Main-thread only; the
    /// mode didSet notifies the palette via onModeChange.
    func endCommandMode() {
        guard mode == .command else { return }
        commandBuffer = ""
        commandIdleTimer?.cancel()
        mode = .normal
    }

    /// Speak-the-options-on-pause: fires once, ~1.5s after the last
    /// COMMAND-mode keystroke. Every keystroke restarts it, so it only
    /// triggers when the user genuinely stops to think.
    private func scheduleCommandIdle() {
        commandIdleTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mode == .command else { return }
            self.onCommandIdle?()
        }
        commandIdleTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: - Escape Tap/Hold (INSERT mode)

    /// Escape keyUp: resolves a withheld press as a tap, or absorbs the
    /// trailing keyUp of a hold that already fired. Any other Escape keyUp
    /// passes through (apps ignore orphan keyUps anyway).
    private func handleEscapeKeyUp(pass: Unmanaged<CGEvent>) -> Unmanaged<CGEvent>? {
        if pendingReadingEscape != nil {
            // READING: released before the hold threshold — a tap = pause
            // (or resume a paused read), exactly like Space
            pendingReadingEscape?.cancel()
            pendingReadingEscape = nil
            DispatchQueue.main.async { [self] in onPauseToggle?() }
            return nil
        }
        if pendingEscapeHold != nil {
            flushPendingEscapeAsTap()
            return nil // the synthetic down+up replaces the real events
        }
        if escapeHoldFired {
            escapeHoldFired = false
            return nil
        }
        return pass
    }

    /// Deliver the withheld Escape press to the app as a synthetic tap.
    private func flushPendingEscapeAsTap() {
        pendingEscapeHold?.cancel()
        pendingEscapeHold = nil
        // postKey does CGEvent work — keep it off the tap callback
        DispatchQueue.main.async { [self] in postKey(keycode: 53) }
    }

    // MARK: - Typing-Burst Rescue (NORMAL mode)

    private enum BurstVerdict {
        case swallow                    // withheld/handled by the burst layer
        case pass(Unmanaged<CGEvent>?)  // verdict of a flush redispatch
    }

    // The command-letter and visual-motion tables live in BurstPolicy —
    // one source of truth, shared with the pure decision.
    private static let commandLetterKeys = BurstPolicy.commandLetterKeys

    private func isCommandLetter(_ keycode: Int64) -> Bool {
        BurstPolicy.isCommandLetter(keycode, firefoxFrontmost: isFirefoxFrontmost)
    }

    // MARK: - Firefox Reader narration handoff

    /// Duck + hold media, silence Marduk (via onNarrate), then hand `n` to
    /// Firefox — Narrate treats it as play/pause. Main thread only.
    private func startNarrationHandoff() {
        narrationActive = true
        fputs("[keyboard] narration handoff to Firefox\n", stderr)
        onNarrate?(true)
        // Give the media pause a beat so narration and music don't talk
        // over each other at the start
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in
            guard narrationActive else { return }
            postKey(keycode: 45)
        }
    }

    /// After `8` posts Cmd+Option+R: the Reader document takes a beat to
    /// render and receive focus. Poll until narrationContext() flips, then
    /// start narrating; give up quietly-but-audibly after ~2.5s (page has
    /// no reader view, or focus never entered the document).
    private func pollForReader(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
            guard !narrationActive else { return }
            if Self.narrationContext() {
                startNarrationHandoff()
            } else if attempt < 10 {
                pollForReader(attempt: attempt + 1)
            } else {
                fputs("[keyboard] 8 — reader document never appeared\n", stderr)
                Earcon.error()
            }
        }
    }

    /// True when keyboard focus sits inside a Firefox Reader document — the
    /// context where `n` drives Narrate. Ascends from the focused element
    /// (self included) to the nearest AXWebArea and checks for an
    /// about:reader URL. Chrome text fields (URL bar, find bar) never reach
    /// a web area, and normal pages have normal URLs, so every typing
    /// context returns false. Main queue only — AX is synchronous IPC.
    static func narrationContext() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "org.mozilla.firefox" else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.5)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success,
              let raw = focusedRef,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        var element = raw as! AXUIElement

        for _ in 0..<15 {
            AXUIElementSetMessagingTimeout(element, 0.5)
            var roleRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            if roleRef as? String == "AXWebArea" {
                var urlRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    element, kAXURLAttribute as CFString, &urlRef
                ) == .success else { return false }
                let url = (urlRef as? URL)?.absoluteString ?? (urlRef as? String) ?? ""
                return url.hasPrefix("about:reader")
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element, kAXParentAttribute as CFString, &parentRef
            ) == .success,
                  let parent = parentRef,
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            element = parent as! AXUIElement
        }
        return false
    }

    /// Decide what a NORMAL-mode keypress means while typing rescue is on.
    /// Returns nil when the burst layer has no opinion (fall through to the
    /// regular command dispatch).
    /// Executes the verdict from the pure `BurstPolicy`. Every decision
    /// lives there (and is exhaustively tested in BurstPolicyTests); this
    /// keeps only the side effects — copying events, redispatching,
    /// ordered replay, and the callbacks.
    private func burstIntercept(
        event: CGEvent, keycode: Int64, isAutorepeat: Bool
    ) -> BurstVerdict? {
        let isLetter = Self.alphaKeyCodes.contains(keycode) || keycode == 40
        let verdict = BurstPolicy.classify(
            buffer: burstBuffer.map { $0.getIntegerValueField(.keyboardEventKeycode) },
            keycode: keycode, isLetter: isLetter, isAutorepeat: isAutorepeat,
            firefoxFrontmost: isFirefoxFrontmost,
            releaseAvailable: releaseAvailable)

        switch verdict {
        case .passThrough:
            return nil

        case .swallowRepeat:
            // A held key's repeats never join the buffer and never beep
            // (single beep/command on expiry instead of a machine-gun).
            return .swallow

        case .startBuffer:
            // If the copy fails we can't withhold — behave as today
            guard let copy = event.copy() else { return nil }
            burstBuffer = [copy]
            armBurstTimer()
            return .swallow

        case .append:
            if let copy = event.copy() { burstBuffer.append(copy) }
            armBurstTimer()
            return .swallow

        case .declareTyping:
            declareTyping(currentEvent: event)
            return .swallow

        case .doubleTap(let gesture):
            // Any earlier buffered commands (the s in s-t-t) flush first so
            // they aren't lost; the first key of the pair is consumed here.
            var events = takeBurst()
            events.removeLast()
            for ev in events {
                if redispatch(ev) != nil { enqueueReplay(ev) }
            }
            DispatchQueue.main.async { [self] in
                switch gesture {
                case .time:
                    onAnnounce?(Self.currentTimeAndDate())
                case .update:
                    // EXPRESS lane: the daemon installs immediately when a
                    // prior check knows updates exist, and degrades to a
                    // harmless check otherwise — so deliberate uu skips the
                    // notes, while a stray double-u on an up-to-date system
                    // (the field incident) can never install anything.
                    fputs("[keyboard] uu → express update\n", stderr)
                    onUpdate?()
                case .release:
                    // The daemon asks a spoken y/n before anything
                    // irreversible happens.
                    fputs("[keyboard] dd → cut release\n", stderr)
                    onCutRelease?()
                case .replay:
                    // Content stays out of the log — the replayed text is
                    // an announcement or a document (privacy allowlist).
                    fputs("[keyboard] rr → replay last speech\n", stderr)
                    onReplay?()
                }
            }
            return .swallow

        case .flushThenRedispatch:
            // Flush the v (enters visual synchronously), then redispatch
            // the motion — it lands in the visual block because mode
            // already changed.
            flushBurstAsCommands()
            return .pass(redispatch(event))

        case .flushThenRoute:
            // Resolve the burst as commands, then let this key take its
            // normal — possibly mode-changed — route (a digit after `v`
            // lands in the visual count-prefix; a space after `s i` passes
            // into INSERT).
            flushBurstAsCommands()
            let routed = redispatch(event)
            if routed != nil, let copy = event.copy() {
                // App-bound: queue behind any keys the flush itself queued
                // (e.g. "sir" + space — the r is still waiting to be posted)
                // so nothing races ahead of the ordered replay.
                enqueueReplay(copy)
                return .swallow
            }
            return .pass(routed)
        }
    }

    /// Arm (or push back) the burst decision timer.
    private func armBurstTimer() {
        burstTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.burstTimer = nil
            self.flushBurstAsCommands()
        }
        burstTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + typingBurstThreshold, execute: work)
    }

    /// Cancel the decision timer and take ownership of the withheld events.
    private func takeBurst() -> [CGEvent] {
        burstTimer?.cancel()
        burstTimer = nil
        let events = burstBuffer
        burstBuffer = []
        return events
    }

    /// Drop all withheld and queued state without executing or replaying it
    /// (mode toggle / teardown — a half-decided burst must not fire later).
    private func discardBurstAndReplay() {
        _ = takeBurst()
        replayQueue = []
    }

    /// Resolve the withheld burst as deliberate commands: redispatch each
    /// buffered event through the real, mode-aware handler. A buffered
    /// command can change mode mid-flush (after a buffered `i` flips to
    /// INSERT, later keys must be typed, not run as commands), so this must
    /// not short-circuit into a NORMAL-only dispatch. A pass verdict means
    /// the event turned out to be app-bound and was never really delivered —
    /// queue it for ordered posting.
    private func flushBurstAsCommands() {
        for ev in takeBurst() {
            if redispatch(ev) != nil { enqueueReplay(ev) }
        }
    }

    /// Re-enter handleEvent with the burst hook bypassed, so the event
    /// reaches the regular dispatch for whatever mode the flush is in. The
    /// only place that touches isFlushingBurst.
    private func redispatch(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        isFlushingBurst = true
        defer { isFlushingBurst = false }
        return handleEvent(type: .keyDown, event: event)
    }

    /// The burst looks like typing: drop into INSERT and replay the
    /// withheld keys into the app so nothing is lost.
    private func declareTyping(currentEvent: CGEvent) {
        var events = takeBurst()
        if let copy = currentEvent.copy() { events.append(copy) }
        // A burst that resolves as typing predates any read that started
        // mid-burst — the user's typing intent wins over the capture
        readingCapture = false
        mode = .insert
        fputs("[keyboard] typing burst (\(events.count) keys) → INSERT\n", stderr)
        DispatchQueue.main.async { Earcon.fallToInsert() }
        for ev in events { enqueueReplay(ev) }
    }

    /// Tag an app-bound event with the synthetic marker and queue it; a
    /// single main-queue drain posts the queue in order, as down+up PAIRS.
    /// The pair matters: the key's real keyUp was never intercepted and
    /// usually reached the app BEFORE this down gets posted, so it cannot
    /// complete the pair — without a synthetic up, apps that track key-held
    /// state (games, hold-to-preview UIs) see the key stuck down forever.
    private func enqueueReplay(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        replayQueue.append(event)
        if replayQueue.count > 1 { return } // a drain is already scheduled
        DispatchQueue.main.async { [self] in
            for down in replayQueue {
                down.post(tap: .cghidEventTap)
                let keycode = CGKeyCode(down.getIntegerValueField(.keyboardEventKeycode))
                if let source = CGEventSource(stateID: .hidSystemState),
                   let up = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: false) {
                    up.flags = down.flags
                    up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
                    up.post(tap: .cghidEventTap)
                }
            }
            replayQueue = []
        }
    }

    // NORMAL-mode command keys that must fire once per physical press —
    // derived from commandLetterKeys so a future command letter can't be
    // added to one set but not the other, plus Escape (53).
    // 45 = n and 2 = d: one-shot even though neither is a command LETTER
    // (both stay out of the rescue's table so words keep their typing
    // rescue) — suppressing a held n's or d's autorepeat everywhere is
    // harmless (NORMAL mode letters don't type anyway) and stops a leaned-on
    // key from reopening the news or restarting the brief on every repeat.
    private static let oneShotNormalKeys: Set<Int64> = commandLetterKeys.union([53, 45, 2])

    // macOS key codes for a-z suppressed in Normal mode to prevent typing.
    // Note: k (40) is deliberately omitted so it passes through to the app.
    /// Keycode → typed character for COMMAND-mode input and typing echo
    /// (US ANSI; shift ignored — the parser is case-insensitive anyway).
    private static let commandKeyChars: [Int64: Character] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
        8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y",
        17: "t", 31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k",
        45: "n", 46: "m",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4",
        23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        49: " ",
    ]

    /// Unmapped keys that are still "typing" (punctuation row) — in COMMAND
    /// mode these buzz instead of leaking into the app. Everything else
    /// unmapped passes through (F-keys, keypad, custom shortcut codes).
    private static let typingPunctuationKeys: Set<Int64> = [
        24, 27, 30, 33, 39, 41, 42, 43, 44, 47, 50,  // = - ] [ ' ; \ , / . `
    ]

    private static let alphaKeyCodes: Set<Int64> = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, // a-r, roughly
        31, 32, 34, 35, 37, 38, 45, 46                              // o-z, roughly (minus k=40)
    ]

    /// R — continuous reading: the FULL text of whatever document is in
    /// view, from the caret (or selection start) to the end, through the
    /// normal read pipeline, so every reading-mode feature (motions,
    /// search, spell, purple border) applies for free.
    ///
    /// The LADDER, in order — each rung is platform-generic, no app is
    /// named anywhere in it:
    ///   1. the focused element's own AX text value
    ///   2. the LONGEST AXTextArea below the focused element (Notes
    ///      focuses a wrapper view; length is what tells the document
    ///      body from a title box sharing that wrapper)
    ///   3. the window's PDF file, via PDFKit (Preview)
    ///   4. an AXTextArea below the WINDOW — reached when focus is
    ///      nowhere useful or nowhere at all
    ///   5. the window's web area (browsers), else the honest buzz
    ///
    /// Rungs 3-5 are what make R work on a document the user has merely
    /// LOOKED at: a freshly opened window often reports NO focused UI
    /// element at all, and this used to bail there with "No readable
    /// document here" — the user had to click into the text or Cmd+A
    /// first just to give the app a focused element to answer with
    /// (field 2026-07-23, Pages and Preview). A missing focus is not a
    /// missing document; it only means nobody has claimed the keyboard.
    /// Main-queue AX for the single-attribute reads (0.5s timeouts),
    /// off-main for every WALK — the focused-container descent included.
    private func readDocumentFromCaret() {
        DispatchQueue.main.async { [self] in
            guard let app = NSWorkspace.shared.frontmostApplication else { return }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.5)

            var focusedRef: CFTypeRef?
            let focusErr = AXUIElementCopyAttributeValue(
                axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef)
            // Tell the TRUTH about a broken permission — "no readable
            // document" sent the user hunting the wrong problem while
            // the real one was a revoked Accessibility grant
            if focusErr.rawValue == -25211 {
                Self.noteAXError(focusErr.rawValue)
                fputs("[keyboard] R: AX API disabled (-25211)\n", stderr)
                Earcon.error()
                return
            }
            if focusErr == .success, let raw = focusedRef,
               CFGetTypeID(raw) == AXUIElementGetTypeID() {
                let element = raw as! AXUIElement
                AXUIElementSetMessagingTimeout(element, 0.5)
                // Rung 1 is one attribute read — cheap enough for main.
                if let text = Self.textValue(of: element) {
                    readFocusedText(text, from: element)
                    return
                }
                // Rung 2 is a WALK, so it goes off-main like every other
                // wide AX walk here, and the ladder resumes on its way back.
                DispatchQueue.global(qos: .utility).async { [self] in
                    let area = Self.longestTextArea(below: element, depth: 8)
                    // Embedded tables are SEPARATE subtrees the text-area
                    // harvest never visits — hunt them from the window
                    // (they're often the text area's far siblings).
                    let tables = Self.collectTableTexts(
                        below: Self.tableRoot(for: element))
                    if !tables.isEmpty {
                        fputs("[keyboard] R: table harvest (\(tables.count), "
                            + "\(TableText.totalLength(tables)) chars)\n", stderr)
                    }
                    DispatchQueue.main.async { [self] in
                        guard let area else {
                            continueDocumentLadder(
                                app: app,
                                fallback: tables.isEmpty ? nil
                                    : DocumentHarvest(element: nil, text: "",
                                                      tables: tables))
                            return
                        }
                        AXUIElementSetMessagingTimeout(area.element, 0.5)
                        fputs("[keyboard] R: descended to text area "
                            + "(\(area.text.count) chars)\n", stderr)
                        // A descent is a GUESS — nobody focused that text
                        // area, we picked it — so a thin one doesn't get to
                        // end the ladder. Pages, opened and not clicked
                        // into, focuses a wrapper whose text areas include a
                        // 14-character title box: R read those 14 characters
                        // and stopped while the body sat one branch over
                        // (field 2026-07-25). Set it aside, keep descending;
                        // if nothing better turns up it is still read,
                        // because a genuinely tiny document is still a
                        // document. The FOCUSED element's own value (rung 1)
                        // is never second-guessed this way — that one is a
                        // fact the user established, not our guess. The
                        // floor counts body + tables: a title box beside a
                        // big table IS the document (field 2026-07-29).
                        guard area.text.count + TableText.totalLength(tables)
                                < Self.documentTextFloor else {
                            speakDocumentText(area.text, from: area.element,
                                              tables: tables)
                            return
                        }
                        fputs("[keyboard] R: descended text is thin — "
                            + "trying the window\n", stderr)
                        continueDocumentLadder(
                            app: app,
                            fallback: DocumentHarvest(element: area.element,
                                                      text: area.text,
                                                      tables: tables))
                    }
                }
                return
            }

            fputs("[keyboard] R: no focused element "
                + "(\(focusErr.rawValue)) — trying the window\n", stderr)
            continueDocumentLadder(app: app, fallback: nil)
        }
    }

    /// A set-aside document harvest riding the ladder down: a thin
    /// focused text and/or the tables found beside it — outranks nothing
    /// but the buzz. `element` nil means no single text element owns the
    /// harvest (table-only), so there is no caret or pointer to honor and
    /// the read starts at the top.
    struct DocumentHarvest {
        let element: AXUIElement?
        let text: String
        let tables: [String]
    }

    /// The rungs below focus. PDF viewers (Preview) expose almost no AX
    /// text, so read the FILE: the window's document path + PDFKit gives
    /// per-page text and pages become first-class reading targets. Then
    /// the window walk (a document canvas whose text area nobody has
    /// focused), then the web area — browsers expose no AX text VALUE
    /// either, but their trees hold the visible text (Reader views become
    /// clean article reads). `fallback` is a thin focused harvest that
    /// outranks nothing but the buzz. Main thread.
    private func continueDocumentLadder(
        app: NSRunningApplication,
        fallback: DocumentHarvest?
    ) {
        if readPDFDocument(app: app) { return }
        readWindowDocument(app: app, fallback: fallback)
    }

    /// Rung 1's speak, with the one exception that may delay it: a
    /// U+FFFC attachment anchor in the focused text is the app saying
    /// "an embedded object lives here" — the object's content (a table's
    /// cells) is published as a SEPARATE AX subtree, never in this
    /// string, so an anchor is worth a budgeted off-main table hunt
    /// before speaking. No anchor = the instant path stays instant
    /// (Terminal and every plain text app never pay for the walk).
    private func readFocusedText(_ text: String, from element: AXUIElement) {
        // Bounded scan: this runs on MAIN, and rung 1 is where Terminal
        // once delivered a 9M-char scrollback (the preprocessor-cap
        // incident). A document that big is paged anyway; an anchor past
        // 100k scalars can wait for a closer read.
        guard text.unicodeScalars.prefix(100_000)
                .contains(where: { $0.value == 0xFFFC }) else {
            speakDocumentText(text, from: element)
            return
        }
        fputs("[keyboard] R: attachment anchor in focused text — "
            + "hunting tables\n", stderr)
        let root = Self.tableRoot(for: element)
        DispatchQueue.global(qos: .utility).async { [self] in
            let tables = Self.collectTableTexts(below: root)
            if !tables.isEmpty {
                fputs("[keyboard] R: table harvest (\(tables.count), "
                    + "\(TableText.totalLength(tables)) chars)\n", stderr)
            }
            DispatchQueue.main.async { [self] in
                speakDocumentText(text, from: element, tables: tables)
            }
        }
    }

    /// Where to hunt a document's tables: the containing window when AX
    /// will name it — tables are usually the text area's FAR siblings,
    /// not its neighbors — else the app's document window, else the
    /// element itself (which a hunt can't descend past: an AXTextArea
    /// root returns instantly, so the fallbacks matter and the log says
    /// which root won).
    private static func tableRoot(for element: AXUIElement) -> AXUIElement {
        var windowRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            element, kAXWindowAttribute as CFString, &windowRef)
        if let raw = windowRef, CFGetTypeID(raw) == AXUIElementGetTypeID() {
            return (raw as! AXUIElement)
        }
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success, pid != 0 {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.25)
            if let window = documentWindow(of: axApp) {
                fputs("[keyboard] R: table root via document window "
                    + "(element answered no AXWindow)\n", stderr)
                return window
            }
        }
        fputs("[keyboard] R: table root is the element itself "
            + "(no window found — hunt will see nothing)\n", stderr)
        return element
    }

    // MARK: - Cursor-placement ledger (recording + judgment)

    /// Tap-callback path: array append only.
    private func noteClick(at point: CGPoint) {
        guard frontmostPID > 0 else { return }
        recentClicks.append(ClickRecord(pid: frontmostPID, point: point))
        if recentClicks.count > Self.clickLedgerCap {
            recentClicks.removeFirst()
        }
    }

    /// Tap-callback path: a keyDown that reached the app. Cmd/Ctrl/Option
    /// combos never mark — Cmd+Tab fires while the OLD app is still
    /// frontmost, and the user's zoom shortcuts ride Option (a zoom-in on
    /// a fresh Pages must not bless its restored caret). Plain and
    /// shifted keys, arrows included, all mean the caret is theirs. The
    /// focused-window fetch is debounced and dispatched off-main; while
    /// Marduk is toggled off the mark degrades to app-level (standing
    /// down means no AX traffic).
    private func noteDeliveredKey(_ event: CGEvent) {
        let flags = event.flags
        guard !flags.contains(.maskCommand), !flags.contains(.maskControl),
              !flags.contains(.maskAlternate) else { return }
        let pid = frontmostPID
        guard pid > 0 else { return }
        guard isEnabled else {
            typedApps.insert(pid)
            return
        }
        let now = Date()
        if let last = lastWindowMark[pid],
           now.timeIntervalSince(last) < Self.windowMarkDebounce { return }
        lastWindowMark[pid] = now
        DispatchQueue.global(qos: .utility).async { [self] in
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.5)
            var ref: CFTypeRef?
            let window: AXUIElement?
            if AXUIElementCopyAttributeValue(
                   axApp, kAXFocusedWindowAttribute as CFString, &ref
               ) == .success,
               let raw = ref, CFGetTypeID(raw) == AXUIElementGetTypeID() {
                window = (raw as! AXUIElement)
            } else {
                window = nil
            }
            DispatchQueue.main.async { [self] in
                guard let window else {
                    // Window unknowable — bless the whole app (the safe,
                    // coarser direction: behaves like the per-app ledger)
                    typedApps.insert(pid)
                    return
                }
                var list = typedWindows[pid] ?? []
                if !list.contains(where: { CFEqual($0, window) }) {
                    list.append(window)
                    if list.count > Self.typedWindowCap { list.removeFirst() }
                    typedWindows[pid] = list
                }
            }
        }
    }

    /// Drop everything keyed by a process that has quit. Main-thread only
    /// (the ledgers are tap state).
    private func forgetProcess(_ pid: pid_t) {
        typedApps.remove(pid)
        typedWindows.removeValue(forKey: pid)
        lastWindowMark.removeValue(forKey: pid)
        prewatchWindows.removeValue(forKey: pid)
        AXNudge.shared.forget(pid: pid)
    }

    /// One AXWindows fetch per already-running GUI app, off-main. Runs
    /// when the tap comes up (evidence collection begins with the tap —
    /// clicks and keystrokes before it were invisible, so windows from
    /// before it stay trusted).
    private func sweepPrewatchWindows() {
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map(\.processIdentifier)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var snapshots: [pid_t: [AXUIElement]] = [:]
            for pid in pids {
                let axApp = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(axApp, 0.5)
                var ref: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                          axApp, kAXWindowsAttribute as CFString, &ref
                      ) == .success,
                      let windows = ref as? [AXUIElement] else { continue }
                // An empty list is a real answer: every later window of
                // this app is fresh under our watch
                snapshots[pid] = windows
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.prewatchWindows = snapshots
                fputs("[keyboard] ledger: window snapshots for "
                      + "\(snapshots.count) of \(pids.count) running apps\n",
                      stderr)
            }
        }
    }

    /// R-time judgment, main thread. Evidence (typed apps, typed windows,
    /// click geometry) blesses regardless of when the app launched; only
    /// an evidence-less window falls to the freshness question.
    private func userPlacedCursor(in element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid != 0 else {
            return true  // can't attribute — trust the caret
        }
        if typedApps.contains(pid) { return true }
        let window = Self.containingWindow(of: element)
        if Self.windowTyped(window, in: typedWindows[pid] ?? []) {
            return true
        }
        let clicks = recentClicks.filter { $0.pid == pid }.map(\.point)
        if Self.clickPlacedCursor(clicks,
                                  within: Self.elementFrame(of: element)) {
            return true
        }
        // No evidence. An app launched under our watch has only fresh
        // windows; a pre-watch app is judged window by window against its
        // startup snapshot — its history is unknowable, its window SET at
        // sweep time was not.
        let launchedUnderWatch = NSRunningApplication(
            processIdentifier: pid)?.launchDate.map { $0 >= monitorStart }
            ?? false
        if launchedUnderWatch { return false }
        return Self.windowPredatesWatch(window,
                                        snapshot: prewatchWindows[pid])
    }

    /// Pure, unit-tested: does the pre-watch snapshot say this window
    /// already existed when evidence collection began? No snapshot for
    /// the app (sweep failed, AX denied, app launched mid-sweep) → its
    /// history is unknown → trust the caret. An unresolvable window
    /// likewise. Absent from a real snapshot → the window appeared under
    /// our watch: fresh, the caret must be earned.
    static func windowPredatesWatch(_ window: AXUIElement?,
                                    snapshot: [AXUIElement]?) -> Bool {
        guard let snapshot else { return true }
        guard let window else { return true }
        return snapshot.contains { CFEqual($0, window) }
    }

    /// Pure, unit-tested: does a typed-window ledger bless this element's
    /// window? An unresolvable window with ANY typed window in the app
    /// blesses — we can't distinguish, and unknowns trust the caret.
    static func windowTyped(_ window: AXUIElement?,
                            in marked: [AXUIElement]) -> Bool {
        guard !marked.isEmpty else { return false }
        guard let window else { return true }
        return marked.contains { CFEqual($0, window) }
    }

    /// Pure, unit-tested: did a recorded click land in the element's
    /// frame? Both are global top-left-origin coordinates. No frame to
    /// judge against → any click in the app blesses (unknowns trust the
    /// caret). Known limit: moving or resizing the window after the click
    /// orphans the point — the user re-clicks, and typing marks too.
    static func clickPlacedCursor(_ clicks: [CGPoint],
                                  within frame: CGRect?) -> Bool {
        guard let frame else { return !clicks.isEmpty }
        return clicks.contains { frame.contains($0) }
    }

    private static func containingWindow(
        of element: AXUIElement
    ) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, kAXWindowAttribute as CFString, &ref) == .success,
              let raw = ref, CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        return (raw as! AXUIElement)
    }

    private static func elementFrame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, kAXPositionAttribute as CFString,
                  &posRef) == .success,
              AXUIElementCopyAttributeValue(
                  element, kAXSizeAttribute as CFString,
                  &sizeRef) == .success,
              let pr = posRef, CFGetTypeID(pr) == AXValueGetTypeID(),
              let sr = sizeRef, CFGetTypeID(sr) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(pr as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sr as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Speak an element's text as a document read: pick the start offset,
    /// hand the FULL text to the read pipeline, then harvest headings.
    /// Main-thread (AX + the read handoff).
    private func speakDocumentText(_ text: String, from element: AXUIElement,
                                   tables: [String] = []) {
        // Start position: the character under the mouse POINTER wins
        // when it's over this element's text — in Terminal the shell
        // caret is pinned to the prompt, so pointing is the only way
        // to say "start here"; in editable apps clicking moves the
        // caret to the pointer anyway, so the two rarely disagree.
        // Falls back to the caret / selection start, then the top.
        // Snapped to the word start, same landing rule as char-find.
        var start = 0
        // Start priority: an EXPLICIT selection outranks everything —
        // Cmd+A then R means "read it all from the top", a selected
        // word means "start here"; the user just said what they want
        // (user-requested). A collapsed cursor (length 0) claims
        // nothing and falls through to the pointer chain. The pointer
        // is by definition ON SCREEN — an offset outside the visible
        // character range is provably garbage (field: Terminal with a
        // 9M-char scrollback answered RangeForPosition with ~2k, the
        // top of the buffer, while the user pointed at the visible
        // bottom). Reject it and fall onward.
        //
        // Then a DELIBERATE caret (`deliberateCaret` — an interior
        // insertion point the user placed, as opposed to a prompt sitting
        // at the end of a buffer), and only then the row estimate — built
        // FROM the visible range, and a guess. Facts before guesses: the
        // row estimate used to come first and R in Pages started several
        // lines below the blinking cursor (field 2026-07-25), because
        // Pages answers no range-for-position while the clamped fraction
        // always answers something. Terminal is untouched: its caret sits
        // at the prompt with nothing after it, claims nothing, and the
        // row estimate still carries the read. Then the top.
        var selection = CFRange(location: 0, length: 0)
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
               element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
           ) == .success,
           let rr = rangeRef, CFGetTypeID(rr) == AXValueGetTypeID() {
            _ = AXValueGetValue(rr as! AXValue, .cfRange, &selection)
        }
        let visibleRange = Self.visibleCharacterRange(of: element)
        let ns = text as NSString
        if selection.length > 0 {
            start = max(0, selection.location)
            fputs("[keyboard] R: starting at selection\n", stderr)
        } else if !userPlacedCursor(in: element) {
            // Fresh window: nobody has clicked or typed here since it
            // appeared, so the caret is app-restored and the pointer just
            // happens to rest somewhere — every guess rung below would
            // start the read at a place nobody picked. Read from the top.
            // (An explicit selection above still wins; the first click or
            // keystroke into the window restores the rungs.)
            start = 0
            fputs("[keyboard] R: fresh window — starting at the top\n",
                  stderr)
        } else if let pointerOffset = Self.textOffsetAtPointer(in: element),
           Self.validatedPointerOffset(pointerOffset,
                                       visible: visibleRange) != nil {
            start = pointerOffset
            fputs("[keyboard] R: starting at pointer\n", stderr)
        } else if let caret = Self.deliberateCaret(max(0, selection.location),
                                                   in: ns) {
            start = caret
            fputs("[keyboard] R: starting at the caret\n", stderr)
        } else if let estimate = Self.pointerRowEstimate(in: element, text: ns) {
            start = estimate
            fputs("[keyboard] R: starting at pointer (row estimate)\n", stderr)
        } else {
            start = max(0, selection.location)  // caret position
        }
        start = ReadNavigator.wordStart(in: text, at: start)

        // Tables append AFTER the offset math: every AX-derived offset
        // above (selection, pointer, caret, row estimate) indexes the
        // element's own value, and appending is exactly what keeps that
        // prefix byte-identical (see TableText).
        let full = TableText.merged(document: text, tables: tables)
        let fullNS = full as NSString
        let remainder = fullNS.substring(from: min(start, fullNS.length))
        guard !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fputs("[keyboard] R: nothing after the caret\n", stderr)
            Earcon.error()
            onAnnounce?("Nothing after the cursor to read.")
            return
        }
        fputs("[keyboard] R: document read (\(remainder.count) of \(fullNS.length) chars)\n", stderr)
        // Full text + start, never the sliced remainder: a huge document
        // gets chunked into pages around the exact start offset, a plain
        // one is retained whole with the voice starting at the offset —
        // either way pre-caret text stays reachable (gg = the true top).
        onSpeakDocument?(full, start)
        harvestRichTextHeadings(from: element, textLength: ns.length,
                                spokenLength: fullNS.length)
    }

    /// Rich-text heading harvest — the rung that gives Notes and TextEdit
    /// heading jumps (Pages historically answers no attributed strings
    /// and degrades to zero headings: the honest buzz, no code path).
    /// Fires AFTER the read dispatched, off-main, never blocking speech:
    /// one parameterized attributed-string fetch over the whole value,
    /// font runs → HeadingDetector (size-prominence, pure) → WHOLE-
    /// document line indices → the same onHarvestHeadings bridge the web
    /// path uses. The lines used to be filtered and rebased to the start
    /// offset, because the plain path spoke `substring(from: start)`; it
    /// now retains the whole document, so headings above the start are
    /// both correctly placed and reachable (]] [[ after a gg). Plain
    /// reads only: a document over one window rides synthetic pages,
    /// whose global-offset mapping is a future rung. Any fetch failure
    /// returns silently — motions buzz. Two lengths on purpose:
    /// `textLength` is the ELEMENT's own value (the attributed fetch
    /// ranges over it — asking past its end fails the whole fetch), while
    /// `spokenLength` is what the read will actually speak, tables
    /// included — the paged-or-plain question belongs to that one.
    /// Heading line indices stay valid either way: appended tables never
    /// move a line in the body prefix.
    private func harvestRichTextHeadings(from element: AXUIElement,
                                         textLength: Int,
                                         spokenLength: Int) {
        guard spokenLength <= PagedText.windowBudget else {
            fputs("[keyboard] R: heading harvest skipped (paged read)\n", stderr)
            return
        }
        let generation = readGenerationProvider?() ?? 0
        DispatchQueue.global(qos: .utility).async { [self] in
            var range = CFRange(location: 0, length: textLength)
            guard let rangeValue = AXValueCreate(.cfRange, &range) else { return }
            var attrRef: CFTypeRef?
            AXUIElementSetMessagingTimeout(element, 0.5)
            guard AXUIElementCopyParameterizedAttributeValue(
                      element,
                      kAXAttributedStringForRangeParameterizedAttribute as CFString,
                      rangeValue, &attrRef) == .success,
                  let attributed = attrRef as? NSAttributedString,
                  attributed.length > 0 else { return }
            let found = HeadingDetector.headings(runs: Self.fontRuns(in: attributed))
            guard !found.isEmpty else { return }
            let text = attributed.string
            let lines = found.map {
                (line: Self.lineIndex(of: $0.offset, in: text), level: $0.level)
            }
            fputs("[keyboard] R: rich-text headings (\(lines.count))\n", stderr)
            DispatchQueue.main.async { [self] in
                guard (readGenerationProvider?() ?? 0) == generation else { return }
                onHarvestHeadings?(lines)
            }
        }
    }

    /// Font runs from an AX attributed string: the "AXFont" attribute is
    /// a dictionary ({AXFontName, AXFontSize, …}) — size is all the
    /// detector needs.
    private static func fontRuns(in attributed: NSAttributedString)
        -> [HeadingDetector.FontRun] {
        var runs: [HeadingDetector.FontRun] = []
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(NSAttributedString.Key("AXFont"), in: full) {
            value, range, _ in
            guard let dict = value as? [String: Any],
                  let size = (dict["AXFontSize"] as? NSNumber)?.doubleValue else { return }
            runs.append(HeadingDetector.FontRun(range: range, pointSize: size))
        }
        return runs
    }

    /// A collapsed caret the user PLACED, as opposed to one that merely
    /// sits wherever output stopped. Pure, unit-tested. Two shapes carry
    /// no information and fall through to the pointer:
    ///
    /// - offset 0, indistinguishable from an app that doesn't answer
    ///   `kAXSelectedTextRangeAttribute` at all (the CFRange is
    ///   zero-initialised, and a failed copy leaves it that way), and
    /// - a caret with nothing but whitespace after it — a shell prompt
    ///   pinned to the end of the buffer, or the end of a document.
    ///   Terminal's caret is ALWAYS there, which is the whole reason the
    ///   pointer outranks the caret in the first place.
    ///
    /// Anything else is a deliberate insertion point: the user clicked
    /// there, and "read from here" means from THERE — not from a line
    /// picked out of the pointer's vertical fraction of the frame. Field
    /// 2026-07-25: R in Pages started several lines below the blinking
    /// cursor on every press (`starting at pointer (row estimate)` in the
    /// log), because Pages doesn't answer range-for-position and the
    /// row-estimate GUESS outranked the caret FACT.
    ///
    /// The lookahead is bounded: this runs on the main thread beside the
    /// event tap, and "is there content after the caret" must not scan a
    /// 9M-char Terminal scrollback to answer.
    static func deliberateCaret(_ location: Int, in text: NSString,
                                lookahead: Int = 4096) -> Int? {
        guard location > 0, location < text.length else { return nil }
        let end = min(text.length, location + max(1, lookahead))
        for i in location..<end {
            switch text.character(at: i) {
            case 0x20, 0x09, 0x0A, 0x0D, 0xA0:  // space, tab, LF, CR, NBSP
                continue
            default:
                return location
            }
        }
        return nil
    }

    /// Pure sanity check, unit-tested: a pointer-derived text offset must
    /// lie within the element's visible character range (nil range = no
    /// information, trust the offset). Returns nil for garbage.
    static func validatedPointerOffset(_ offset: Int, visible: NSRange?) -> Int? {
        guard let visible, visible.length > 0 else { return offset }
        let inRange = offset >= visible.location
            && offset <= visible.location + visible.length
        if !inRange {
            fputs("[keyboard] R: pointer offset \(offset) outside visible "
                + "range \(visible.location)..\(visible.location + visible.length) "
                + "— using row estimate\n", stderr)
        }
        return inRange ? offset : nil
    }

    private static func visibleCharacterRange(of element: AXUIElement) -> NSRange? {
        var visRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, kAXVisibleCharacterRangeAttribute as CFString,
                  &visRef) == .success,
              let vr = visRef, CFGetTypeID(vr) == AXValueGetTypeID() else { return nil }
        var visible = CFRange(location: 0, length: 0)
        guard AXValueGetValue(vr as! AXValue, .cfRange, &visible) else { return nil }
        return NSRange(location: visible.location, length: visible.length)
    }

    /// Row-estimate fallback for pointer starts when the app doesn't
    /// answer range-for-position (Terminal, empirically): the pointer's
    /// vertical fraction of the element's frame picks a line inside the
    /// VISIBLE character range. Terminal rows are uniform height, so this
    /// is line-accurate — all a "start here" gesture needs (the wordStart
    /// snap afterwards lands cleanly).
    ///
    /// It is a GUESS, and the fraction is clamped, so it answers even when
    /// the pointer is nowhere near the text — which is why a deliberate
    /// caret now outranks it (`deliberateCaret`). It stays the last resort
    /// for the apps whose caret says nothing.
    private static func pointerRowEstimate(in element: AXUIElement,
                                           text: NSString) -> Int? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        var visRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(
                  element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              AXUIElementCopyAttributeValue(
                  element, kAXVisibleCharacterRangeAttribute as CFString, &visRef) == .success,
              let pr = posRef, CFGetTypeID(pr) == AXValueGetTypeID(),
              let sr = sizeRef, CFGetTypeID(sr) == AXValueGetTypeID(),
              let vr = visRef, CFGetTypeID(vr) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        var visible = CFRange(location: 0, length: 0)
        guard AXValueGetValue(pr as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sr as! AXValue, .cgSize, &size), size.height > 0,
              AXValueGetValue(vr as! AXValue, .cfRange, &visible),
              visible.length > 0 else { return nil }

        // AX frames are top-left origin, same conversion as textOffsetAtPointer
        let mouse = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let axY = primaryHeight - mouse.y
        let fraction = max(0.0, min(1.0, (axY - origin.y) / size.height))

        let visStart = max(0, min(visible.location, text.length))
        let visEnd = max(visStart, min(visible.location + visible.length, text.length))
        let visibleText = text.substring(
            with: NSRange(location: visStart, length: visEnd - visStart))
        let lines = visibleText.components(separatedBy: "\n")
        guard !lines.isEmpty else { return nil }
        let targetLine = min(lines.count - 1, Int(fraction * CGFloat(lines.count)))
        var offset = visStart
        for index in 0..<targetLine {
            offset += (lines[index] as NSString).length + 1
        }
        return min(offset, text.length)
    }

    /// The text offset under the mouse pointer, via the parameterized
    /// AXRangeForPosition attribute (how hover speech maps pointer→text).
    /// Nil when the element doesn't support it or the pointer isn't over
    /// its text. AX coordinates are top-left origin; NSEvent's are
    /// bottom-left — flip against the primary screen's height.
    private static func textOffsetAtPointer(in element: AXUIElement) -> Int? {
        let mouse = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        var point = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
        guard let pointValue = AXValueCreate(.cgPoint, &point) else { return nil }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                  element,
                  kAXRangeForPositionParameterizedAttribute as CFString,
                  pointValue, &rangeRef
              ) == .success,
              let rr = rangeRef, CFGetTypeID(rr) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rr as! AXValue, .cfRange, &range),
              range.location >= 0 else { return nil }
        return range.location
    }

    /// An element's AX text value, or nil when it has none (unsupported
    /// attribute, wrong type, or empty).
    private static func textValue(of element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String, !text.isEmpty else { return nil }
        return text
    }

    /// The window R should read: the focused one, else the main one, else
    /// the first in the list. A window the user is LOOKING at need not be
    /// the focused one — an app that has just opened a document, or one
    /// whose focus went to a panel, still answers main/first, and "there
    /// is a document in view" is the whole premise of R.
    private static func documentWindow(of axApp: AXUIElement) -> AXUIElement? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                   axApp, attribute as CFString, &ref) == .success,
               let raw = ref, CFGetTypeID(raw) == AXUIElementGetTypeID() {
                return (raw as! AXUIElement)
            }
        }
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }
        return windows.first
    }

    /// Window rung for R: find the document text WITHOUT the app's help.
    /// Reached when focus yielded nothing — most often because the user
    /// has only looked at the window, never clicked into it, so the app
    /// reports no focused element at all (Pages, Preview; field
    /// 2026-07-23). Falls through to the web rung when the window holds
    /// no document text, so browsers and the honest buzz are unaffected.
    /// The walk is OFF-MAIN (same reason as the web walk: a wide AX walk
    /// on main would stall tap dispatch); the read hops back.
    private func readWindowDocument(
        app: NSRunningApplication,
        fallback: DocumentHarvest? = nil
    ) {
        let pid = app.processIdentifier
        DispatchQueue.global(qos: .utility).async { [self] in
            guard let found = Self.windowDocumentText(pid: pid) else {
                DispatchQueue.main.async { [self] in
                    guard let app = NSRunningApplication(processIdentifier: pid) else {
                        failReadDocument(fallback)
                        return
                    }
                    readWebPage(app: app, fallback: fallback)
                }
                return
            }
            DispatchQueue.main.async { [self] in
                // The window walk answered, but the same length rule that
                // picks the document inside it applies BETWEEN rungs: a
                // window text area shorter than the focused one we set
                // aside is the sidebar, not the document. Tables count on
                // both sides — they're document content wherever found.
                if let fallback,
                   fallback.text.count + TableText.totalLength(fallback.tables)
                       > found.text.count + TableText.totalLength(found.tables) {
                    failReadDocument(fallback)
                } else if let element = found.element {
                    AXUIElementSetMessagingTimeout(element, 0.5)
                    speakDocumentText(found.text, from: element,
                                      tables: found.tables)
                } else {
                    // Canvas harvest: no single text element owns it, so
                    // there is no caret, selection, or offset to honor —
                    // read from the top, which is what "start reading
                    // this document" means anyway.
                    fputs("[keyboard] R: window canvas read "
                        + "(\(found.text.count) chars)\n", stderr)
                    onSpeakDocument?(TableText.merged(document: found.text,
                                                      tables: found.tables), 0)
                }
            }
        }
    }

    /// The document text inside the front window, by AX walk. Two rungs:
    ///
    /// 1. the LONGEST AXTextArea value below the window — a document body
    ///    beats a sidebar note or a comment box, and length is the only
    ///    app-neutral way to say "that's the document";
    /// 2. failing that, the static text below a document CANVAS
    ///    (AXLayoutArea, as iWork-style page canvases publish, else the
    ///    largest scroll area) — canvases expose their text as leaves
    ///    with no text area anywhere. Floored at 200 chars, the same
    ///    thin-harvest floor the web walk uses, so chrome and labels
    ///    can't masquerade as a document.
    ///
    /// A window hosting a web area returns nil on purpose: that is a web
    /// read, and the web rung walks it properly (anchors, headings,
    /// Reader views). Otherwise a stray `<textarea>` on a page would win
    /// over the article. Budgeted like every other walk (0.25s element
    /// timeouts, node and depth caps). Off-main only.
    private static func windowDocumentText(pid: pid_t)
        -> (element: AXUIElement?, text: String, tables: [String])? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        guard let window = documentWindow(of: axApp) else {
            fputs("[keyboard] R: no window to walk\n", stderr)
            return nil
        }
        if findDescendant(of: window, role: "AXWebArea", depthBudget: 12) != nil {
            return nil  // web read — the web rung owns it
        }

        // Tables ride every window harvest: they're separate subtrees no
        // text-area or canvas rung visits (the canvas walk deliberately
        // skips them so the row-ordered harvest here can't double-speak).
        let tables = collectTableTexts(below: window)
        if !tables.isEmpty {
            fputs("[keyboard] R: table harvest (\(tables.count), "
                + "\(TableText.totalLength(tables)) chars)\n", stderr)
        }

        var best: (element: AXUIElement, text: String)?
        var nodeBudget = 600
        collectTextAreas(from: window, best: &best,
                         nodeBudget: &nodeBudget, depth: 12)
        if let best {
            fputs("[keyboard] R: window text area (\(best.text.count) chars)\n", stderr)
            return (best.element, best.text, tables)
        }

        guard let canvas = findDescendant(of: window, role: "AXLayoutArea",
                                          depthBudget: 12)
                ?? findDescendant(of: window, role: "AXScrollArea",
                                  depthBudget: 12) else {
            // No canvas either — a table can still BE the document.
            guard TableText.totalLength(tables) > documentTextFloor else {
                return nil
            }
            return (nil, "", tables)
        }
        var parts: [(text: String, element: AXUIElement)] = []
        var headingMarks: [(partIndex: Int, level: Int)] = []
        var canvasBudget = 3000
        collectText(from: canvas, into: &parts, headingMarks: &headingMarks,
                    nodeBudget: &canvasBudget, depth: 40, skipTables: true)
        let joined = parts.map(\.text).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard joined.count + TableText.totalLength(tables) > documentTextFloor else {
            fputs("[keyboard] R: window canvas harvest thin "
                + "(\(joined.count) chars)\n", stderr)
            return nil
        }
        return (nil, joined, tables)
    }

    /// How much text a harvest needs before it counts as "the document".
    /// Below this a harvest is chrome, a label, or a title box — used by
    /// the web walk, the canvas walk, and the focused-container descent.
    static let documentTextFloor = 200

    /// The LONGEST AXTextArea at or below `element` — the same rule the
    /// window walk uses one level up, applied to the focused container.
    /// Budgeted like every other walk here (nodes, depth, 0.25s element
    /// timeouts) and it stops at each text area. Off-main only.
    private static func longestTextArea(below element: AXUIElement, depth: Int)
        -> (element: AXUIElement, text: String)? {
        var best: (element: AXUIElement, text: String)?
        var nodeBudget = 300
        collectTextAreas(from: element, best: &best,
                         nodeBudget: &nodeBudget, depth: depth)
        return best
    }

    /// The ladder ran out. Speak the thin set-aside harvest if one rode
    /// down — a genuinely tiny document is still a document — else the
    /// honest buzz. A harvest with no owning element (table-only) has no
    /// caret or pointer to honor and reads from the top.
    private func failReadDocument(_ fallback: DocumentHarvest?) {
        guard let fallback else {
            // The walks may have nudged the app's AX flags on the way to
            // nothing; no read will end to take them back, so do it here
            AXNudge.shared.restoreAll(reason: "no document")
            Earcon.error()
            onAnnounce?("No readable document here.")
            return
        }
        if let element = fallback.element {
            fputs("[keyboard] R: nothing better than the focused text "
                + "(\(fallback.text.count) chars)\n", stderr)
            speakDocumentText(fallback.text, from: element,
                              tables: fallback.tables)
            return
        }
        let merged = TableText.merged(document: fallback.text,
                                      tables: fallback.tables)
        guard !merged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Earcon.error()
            onAnnounce?("No readable document here.")
            return
        }
        fputs("[keyboard] R: table-only read (\(merged.count) chars)\n", stderr)
        onSpeakDocument?(merged, 0)
    }

    /// Longest AXTextArea value below `element`. Unlike findDescendant
    /// this can't stop at the first hit: the first text area in a window
    /// is as likely to be a search field's sibling or an empty footnote
    /// as the document.
    private static func collectTextAreas(
        from element: AXUIElement,
        best: inout (element: AXUIElement, text: String)?,
        nodeBudget: inout Int, depth: Int
    ) {
        guard depth > 0, nodeBudget > 0 else { return }
        nodeBudget -= 1
        AXUIElementSetMessagingTimeout(element, 0.25)
        var roleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &roleRef)
        if roleRef as? String == "AXTextArea" {
            if let text = textValue(of: element),
               text.count > (best?.text.count ?? 0) {
                best = (element, text)
            }
            return  // a text area's children are its own text, not another document
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, kAXChildrenAttribute as CFString, &childrenRef
              ) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            guard nodeBudget > 0 else { return }
            collectTextAreas(from: child, best: &best,
                             nodeBudget: &nodeBudget, depth: depth - 1)
        }
    }

    /// Every AXTable's text at or below `root`, in walk order. Embedded
    /// document tables (Pages — the platform pattern, not a Pages code
    /// path) are separate subtrees whose cell text never appears in any
    /// text area's value: the body string holds at most a U+FFFC anchor
    /// where the table sits, so the single-value harvest read up to the
    /// table and went silent (field 2026-07-29). Rows come from the
    /// AXRows attribute (the documented convention), else row-role
    /// children — never columns, which republish the same cells and
    /// would double-speak every one. Budgeted like every walk here
    /// (nodes, depth, 0.25s element timeouts). Off-main only.
    static func collectTableTexts(below root: AXUIElement) -> [String] {
        // iWork-style canvases hold the document's objects under an
        // AXLayoutArea — when one exists, spend the whole budget there
        // instead of on toolbars and inspectors (field 2026-07-29: the
        // window-rooted hunt found nothing in Pages while a table sat on
        // screen; a window's chrome subtrees can eat any budget).
        let canvas = findDescendant(of: root, role: "AXLayoutArea",
                                    depthBudget: 12)
        if canvas != nil {
            fputs("[keyboard] R: table hunt scoped to the layout area\n", stderr)
        }
        let budget = 1500
        var rolesSeen: Set<String> = []
        var visited = 0
        func hunt() -> [String] {
            var tables: [String] = []
            var nodeBudget = budget
            collectTables(from: canvas ?? root, into: &tables,
                          nodeBudget: &nodeBudget, depth: 16,
                          rolesSeen: &rolesSeen)
            visited = budget - nodeBudget
            return tables
        }

        var tables = hunt()
        if tables.isEmpty, nudgeEnhancedUI(for: root) {
            // iWork-style apps populate a table's rows/cells LAZILY, only
            // after an assistive client announces itself (field
            // 2026-07-29: the hunt reached the Pages canvas, found the
            // AXTable, and harvested zero cell text). This is the same
            // AXEnhancedUserInterface nudge the web walk uses — applied
            // only on a miss, so its side effects stay contained to
            // exactly the failing case. One settle beat, one retry;
            // off-main, so the sleep starves nobody.
            Thread.sleep(forTimeInterval: 0.3)
            tables = hunt()
            if !tables.isEmpty {
                fputs("[keyboard] R: table harvest woke after the AX nudge\n",
                      stderr)
            }
        }
        if tables.isEmpty {
            // Blind-iteration diagnostics: roles are AX vocabulary, never
            // user content. What the walk saw tells us whether it reached
            // the canvas at all — and what the app calls a table if not
            // AXTable.
            let sample = rolesSeen.sorted().prefix(20).joined(separator: ",")
            fputs("[keyboard] R: table hunt found none "
                + "(visited \(visited) nodes, "
                + "roles: \(sample))\n", stderr)
        }
        // Pages publishes the same table as TWO identical AXTable
        // elements (field 2026-07-29: matching 13×5 anatomy twice) —
        // identical harvests speak once.
        var seen = Set<String>()
        return tables.filter { seen.insert($0).inserted }
    }

    /// iWork-style apps publish a table's guts only once an assistive
    /// client announces itself; setting the app's AXEnhancedUserInterface
    /// is that announcement (VoiceOver's own behavior, and the web walk's
    /// existing nudge). True = the set was attempted on a resolvable app.
    private static func nudgeEnhancedUI(for element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid != 0 else {
            return false
        }
        // Recorded in the AXNudge ledger so the flag is taken back when
        // the read ends — a per-process flag left on for the app's whole
        // lifetime is a slow-machine bug, not a harmless hint.
        let err = AXNudge.shared.enhance(pid: pid, flags: [.enhanced])
        fputs("[keyboard] R: enhanced-UI nudge sent (\(err.rawValue))\n", stderr)
        return true
    }

    private static func collectTables(
        from element: AXUIElement, into tables: inout [String],
        nodeBudget: inout Int, depth: Int, rolesSeen: inout Set<String>
    ) {
        guard depth > 0, nodeBudget > 0 else { return }
        nodeBudget -= 1
        AXUIElementSetMessagingTimeout(element, 0.25)
        var roleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String
        if let role { rolesSeen.insert(role) }
        // A text area's children are its own text; a web area's tables
        // belong to the web rung's tree-order walk, not this one.
        if role == "AXTextArea" || role == "AXWebArea" { return }
        if role == "AXTable" {
            let text = tableText(of: element)
            if !text.isEmpty {
                tables.append(text)
            } else {
                // Found-but-unharvestable is a different bug than
                // never-found — say so.
                fputs("[keyboard] R: table found but no cell text "
                    + "harvested\n", stderr)
            }
            return  // a nested table reads as part of its parent's cells
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, kAXChildrenAttribute as CFString, &childrenRef
              ) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            guard nodeBudget > 0 else { return }
            collectTables(from: child, into: &tables,
                          nodeBudget: &nodeBudget, depth: depth - 1,
                          rolesSeen: &rolesSeen)
        }
    }

    /// One table's text: ordered rows via the AXRows attribute, else
    /// children whose role says row. Cells come from each row's children;
    /// column elements are deliberately never walked (same cells again).
    private static func tableText(of table: AXUIElement) -> String {
        AXUIElementSetMessagingTimeout(table, 0.25)
        var rows: [AXUIElement] = []
        var viaAttribute = false
        var rowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
               table, "AXRows" as CFString, &rowsRef) == .success,
           let axRows = rowsRef as? [AXUIElement], !axRows.isEmpty {
            rows = axRows
            viaAttribute = true
        } else {
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                   table, kAXChildrenAttribute as CFString, &childrenRef
               ) == .success,
               let children = childrenRef as? [AXUIElement] {
                rows = children.filter { elementRole(of: $0) == "AXRow" }
            }
        }
        var cellBudget = 4000
        let harvested: [[String]] = rows.map { row in
            guard cellBudget > 0 else { return [] }
            AXUIElementSetMessagingTimeout(row, 0.25)
            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                      row, kAXChildrenAttribute as CFString, &childrenRef
                  ) == .success,
                  let kids = childrenRef as? [AXUIElement] else { return [] }
            // The documented recipe: a row's cells are its AXCell
            // children; apps that skip the cell role get all children.
            let cells = kids.filter { elementRole(of: $0) == "AXCell" }
            return (cells.isEmpty ? kids : cells)
                .map { cellText(of: $0, nodeBudget: &cellBudget, depth: 8) }
        }
        let text = TableText.compose(rows: harvested)
        if text.isEmpty {
            logTableAnatomy(of: table, rows: rows, viaAttribute: viaAttribute)
        }
        return text
    }

    /// One line naming an unharvestable table's SHAPE — role names and
    /// counts only, never cell content. This is what turns "table found
    /// but no cell text" from a shrug into the next fix.
    private static func logTableAnatomy(of table: AXUIElement,
                                        rows: [AXUIElement],
                                        viaAttribute: Bool) {
        func histogram(_ elements: [AXUIElement]) -> String {
            var counts: [String: Int] = [:]
            for element in elements.prefix(40) {
                counts[elementRole(of: element) ?? "?", default: 0] += 1
            }
            return counts.sorted { $0.key < $1.key }
                .map { "\($0.key)x\($0.value)" }.joined(separator: ",")
        }
        var childrenRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            table, kAXChildrenAttribute as CFString, &childrenRef)
        let children = (childrenRef as? [AXUIElement]) ?? []
        var line = "[keyboard] R: table anatomy: rows=\(rows.count)"
            + (viaAttribute ? " (AXRows)" : " (children)")
            + ", children [\(histogram(children))]"
        if let firstRow = rows.first {
            var rowKidsRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(
                firstRow, kAXChildrenAttribute as CFString, &rowKidsRef)
            let rowKids = (rowKidsRef as? [AXUIElement]) ?? []
            line += ", row0 [\(histogram(rowKids))]"
            if let firstCell = rowKids.first {
                line += ", cell0 {\(attributeSummary(of: firstCell))}"
            }
        }
        fputs(line + "\n", stderr)
    }

    /// Every attribute a cell answers, tagged by type — names, type
    /// tags, and string LENGTHS only, never content (numbers print as
    /// bare "num": a cell's number IS content). This is the line that
    /// names the carrier when a cell's text hides behind an attribute
    /// nobody documents.
    private static func attributeSummary(of element: AXUIElement) -> String {
        AXUIElementSetMessagingTimeout(element, 0.5)
        var namesRef: CFArray?
        guard AXUIElementCopyAttributeNames(element, &namesRef) == .success,
              let names = namesRef as? [String] else { return "no attributes" }
        return names.prefix(40).map { name -> String in
            var valueRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                      element, name as CFString, &valueRef) == .success,
                  let value = valueRef else { return name + ":nil" }
            if let text = value as? String { return name + ":str\(text.count)" }
            if let attributed = value as? NSAttributedString {
                return name + ":astr\(attributed.length)"
            }
            if value is NSNumber { return name + ":num" }
            if CFGetTypeID(value) == AXUIElementGetTypeID() {
                return name + ":elem"
            }
            if let array = value as? [AnyObject] {
                return name + ":arr\(array.count)"
            }
            return name + ":other"
        }.joined(separator: ",")
    }

    private static func elementRole(of element: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(element, 0.25)
        var roleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &roleRef)
        return roleRef as? String
    }

    /// A cell's text, by every carrier a table cell is known to use:
    /// string value → attributed value → numeric value (Numbers-style
    /// cells publish NSNumber) → text-bearing leaves → title. Field
    /// 2026-07-29: Pages cells answered a full 13×5 AXCell grid and NO
    /// text through value-or-children alone. Timeout 0.5s, not the
    /// walk's 0.25 — a lazily-built cell's first answer is slow.
    private static func cellText(of element: AXUIElement,
                                 nodeBudget: inout Int, depth: Int) -> String {
        guard depth > 0, nodeBudget > 0 else { return "" }
        nodeBudget -= 1
        AXUIElementSetMessagingTimeout(element, 0.5)
        // Scrub per CARRIER, before any join can glue chatter to content
        // — a merged cell's "spans four rows" arrives embedded in the
        // same string as its text, not only as a cell of its own.
        func speakable(_ text: String) -> String? {
            let scrubbed = TableText.scrubSpanChatter(text)
            return scrubbed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : scrubbed
        }
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
               element, kAXValueAttribute as CFString, &valueRef) == .success,
           let value = valueRef {
            if let text = value as? String, let out = speakable(text) {
                return out
            }
            if let attributed = value as? NSAttributedString,
               let out = speakable(attributed.string) {
                return out
            }
            if let number = value as? NSNumber {
                return number.stringValue
            }
        }
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
               element, kAXChildrenAttribute as CFString, &childrenRef
           ) == .success,
           let children = childrenRef as? [AXUIElement], !children.isEmpty {
            let joined = children
                .map { cellText(of: $0, nodeBudget: &nodeBudget, depth: depth - 1) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if let out = speakable(joined) { return out }
        }
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
               element, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String, let out = speakable(title) {
            return out
        }
        return ""
    }

    /// Web-page fallback for R — ANY browser (Safari, Firefox, and the
    /// Chromium family get the same treatment):
    ///
    /// 1. AX WALK of the VISIBLE web area. With a Reader view open
    ///    (Safari Reader via Shift+Cmd+R, Firefox about:reader) the
    ///    visible area IS the stripped article, so the walk reads exactly
    ///    what Reader shows: title and body, no site clutter. (Reader is
    ///    an overlay: Safari AppleScript's `document` stays the full
    ///    underlying page — first-user-verified.) Firefox's `n` handoff
    ///    to its own Narrate is untouched — R is the Marduk-native
    ///    alternative with all the reading motions.
    /// 2. Thin harvest: Safari alone has an AppleScript whole-page
    ///    fallback (`text of front document`, clutter included; first
    ///    use fires the one-time Safari Automation prompt). Everything
    ///    else lands on the standard "No readable document here."
    ///
    /// Off-main throughout.
    /// Scripted whole-page text fallbacks for THIN AX harvests, per
    /// bundle — a table so new rows are data, but honestly narrow: Safari
    /// is the only browser whose AppleScript exposes the page text.
    static let scriptedTextFallbacks: [String: String] = [
        "com.apple.Safari": "tell application \"Safari\" to get text of front document",
    ]

    private func readWebPage(
        app: NSRunningApplication,
        fallback: DocumentHarvest? = nil
    ) {
        let pid = app.processIdentifier
        let fallbackScript = app.bundleIdentifier
            .flatMap { Self.scriptedTextFallbacks[$0] }
        fputs("[keyboard] R: web-area extraction\n", stderr)
        DispatchQueue.global(qos: .utility).async { [self] in
            if let harvest = Self.webAreaVisibleText(pid: pid),
               harvest.text.count > Self.documentTextFloor {
                fputs("[keyboard] R: web-area walk (\(harvest.text.count) chars, "
                    + "\(harvest.anchors.count) anchors, "
                    + "\(harvest.headings.count) headings)\n", stderr)
                DispatchQueue.main.async { [self] in
                    // onSpeak → speak() → onNewRead clears stale anchors
                    // and headings, THEN this read's arm
                    onSpeak?(harvest.text)
                    setWebReadAnchors(harvest.anchors)
                    onHarvestHeadings?(harvest.headings)
                }
                return
            }
            guard let script = fallbackScript else {
                fputs("[keyboard] R: web-area walk thin, no fallback for this app\n", stderr)
                DispatchQueue.main.async { [self] in
                    failReadDocument(fallback)
                }
                return
            }
            fputs("[keyboard] R: AX walk thin — scripted fallback\n", stderr)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            var text: String?
            do {
                try process.run()
                // Kill-on-timeout watchdog — the last osascript in the
                // codebase without one. The FIRST scripted fallback fires
                // Safari's Automation consent prompt, which stalls the
                // script until the user answers (and a wedged Safari never
                // answers): an unbounded drain would strand this worker
                // and the read would never report failure. Terminating
                // closes the pipes, so the drain below unblocks.
                let watchdog = DispatchWorkItem { [weak process] in
                    guard let process, process.isRunning else { return }
                    fputs("[keyboard] scripted extraction timed out — "
                        + "killing osascript\n", stderr)
                    process.terminate()
                }
                DispatchQueue.global(qos: .utility)
                    .asyncAfter(deadline: .now() + 10, execute: watchdog)
                // Drain before waiting — the pipe-buffer deadlock guard
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let err = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                if process.terminationStatus == 0 {
                    text = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    let msg = String(data: err, encoding: .utf8) ?? ""
                    fputs("[keyboard] scripted extraction failed (status "
                        + "\(process.terminationStatus)): "
                        + "\(msg.trimmingCharacters(in: .whitespacesAndNewlines))\n", stderr)
                }
            } catch {
                fputs("[keyboard] osascript launch failed: \(error.localizedDescription)\n", stderr)
            }
            DispatchQueue.main.async { [self] in
                guard let text, !text.isEmpty else {
                    failReadDocument(fallback)
                    return
                }
                fputs("[keyboard] R: Safari page (\(text.count) chars)\n", stderr)
                onSpeakDocument?(text, 0)  // unbounded harvest — may page
            }
        }
    }

    /// Harvest the text visible in the app's front web area by walking
    /// its AX tree (static text + headings, in document order). Returns
    /// nil on a sparse tree — browsers populate web AX lazily; the
    /// nudges below help but only real hardware proves each browser.
    /// Budgeted: 0.25s per-element timeouts, capped node count and depth,
    /// so a pathological page can't wedge the walk. Runs OFF the main
    /// thread by design (a long walk on main would stall tap dispatch).
    private static func webAreaVisibleText(pid: pid_t)
        -> (text: String, anchors: [AXUIElement], headings: [(line: Int, level: Int)])? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        // The screen-reader nudges: browsers keep web AX trees minimal
        // until an assistive client announces itself. EnhancedUserInterface
        // is the WebKit/Gecko signal; ManualAccessibility is the
        // Chromium/Electron one. Setting both is harmless FOR THE READ —
        // leaving them on is not (Chromium runs in full accessibility mode
        // until told otherwise), so both go through the AXNudge ledger and
        // are restored when the read ends.
        AXNudge.shared.enhance(pid: pid, flags: [.enhanced, .manual])
        Thread.sleep(forTimeInterval: 0.3) // let the tree populate

        guard let window = documentWindow(of: axApp) else { return nil }

        // Find the web area, then collect text below it
        guard let webArea = findDescendant(
            of: window, role: "AXWebArea", depthBudget: 12
        ) else { return nil }

        var parts: [(text: String, element: AXUIElement)] = []
        var headingMarks: [(partIndex: Int, level: Int)] = []
        var nodeBudget = 3000
        collectText(from: webArea, into: &parts, headingMarks: &headingMarks,
                    nodeBudget: &nodeBudget, depth: 40)
        let joined = parts.map(\.text).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return nil }
        // One anchor PER LINE of the joined text (a node's text can itself
        // contain newlines), so line index → contributing element is exact
        // before preprocessing and within a line or two after
        var anchors: [AXUIElement] = []
        var lineOfPart: [Int] = []  // cumulative: first line index of part i
        for part in parts {
            lineOfPart.append(anchors.count)
            let lines = part.text.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
            anchors.append(contentsOf: Array(repeating: part.element, count: lines))
        }
        // Heading marks point at the first part their subtree appended;
        // marks whose subtree appended nothing (empty heading) are dropped.
        let headings = headingMarks.compactMap { mark -> (line: Int, level: Int)? in
            guard mark.partIndex < lineOfPart.count else { return nil }
            return (line: lineOfPart[mark.partIndex], level: mark.level)
        }
        return (joined, anchors, headings)
    }

    private static func findDescendant(
        of element: AXUIElement, role: String, depthBudget: Int
    ) -> AXUIElement? {
        guard depthBudget > 0 else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)
        var roleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if roleRef as? String == role { return element }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, kAXChildrenAttribute as CFString, &childrenRef
              ) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let found = findDescendant(of: child, role: role,
                                          depthBudget: depthBudget - 1) {
                return found
            }
        }
        return nil
    }

    private static func collectText(
        from element: AXUIElement, into parts: inout [(text: String, element: AXUIElement)],
        headingMarks: inout [(partIndex: Int, level: Int)],
        nodeBudget: inout Int, depth: Int, skipTables: Bool = false
    ) {
        guard depth > 0, nodeBudget > 0 else { return }
        nodeBudget -= 1
        AXUIElementSetMessagingTimeout(element, 0.25)
        var roleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        // The canvas walk skips tables — collectTableTexts harvests them
        // in row order and would double-speak every cell otherwise. The
        // WEB walk keeps them: web tables' cells arrive here as static
        // text in tree order, and no separate table hunt runs there.
        if skipTables, roleRef as? String == "AXTable" { return }
        if let role = roleRef as? String,
           role == "AXStaticText" || role == "AXHeading" {
            var valueRef: CFTypeRef?
            let gotValue = AXUIElementCopyAttributeValue(
                element, kAXValueAttribute as CFString, &valueRef) == .success
            if role == "AXHeading" {
                // A heading's text usually arrives via its child static-
                // texts (WebKit keeps the integer LEVEL in AXValue), so
                // the mark points at the first part its subtree appends.
                headingMarks.append((partIndex: parts.count,
                                     level: headingLevel(of: element,
                                                         value: gotValue ? valueRef : nil)))
            }
            if gotValue, let text = valueRef as? String,
               !text.trimmingCharacters(in: .whitespaces).isEmpty {
                parts.append((text, element))
            }
            if role == "AXStaticText" { return } // leaves have no useful children
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, kAXChildrenAttribute as CFString, &childrenRef
              ) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            guard nodeBudget > 0 else { return }
            collectText(from: child, into: &parts, headingMarks: &headingMarks,
                        nodeBudget: &nodeBudget, depth: depth - 1,
                        skipTables: skipTables)
        }
    }

    /// A web heading's level. WebKit publishes the integer in the
    /// heading's AXValue; other engines may answer an AXLevel attribute
    /// instead (verify per browser on hardware). Unknown → 2, a flat-but-
    /// sane default: ]] and [[ still work, ][ degrades to ]], ]u buzzes.
    private static func headingLevel(of element: AXUIElement, value: CFTypeRef?) -> Int {
        if let n = value as? Int, (1...6).contains(n) { return n }
        var levelRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXLevel" as CFString, &levelRef) == .success,
           let n = levelRef as? Int, (1...6).contains(n) { return n }
        return 2
    }

    /// PDF fallback for R: the focused window's document path (standard
    /// NSDocument AX) → PDFKit per-page text → paged read. Start page
    /// comes from Preview's "Page 3 of 12" window title when parseable.
    /// AX stays on main; the PDFKit load (big files take a moment) hops
    /// to a utility queue and dispatches back. Returns false when there's
    /// no PDF to try (caller falls through to the normal buzz).
    /// Main-thread only.
    private func readPDFDocument(app: NSRunningApplication) -> Bool {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.5)

        guard let window = Self.documentWindow(of: axApp) else { return false }
        AXUIElementSetMessagingTimeout(window, 0.5)

        var documentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  window, kAXDocumentAttribute as CFString, &documentRef
              ) == .success else { return false }
        let documentPath = (documentRef as? String) ?? (documentRef as? URL)?.absoluteString ?? ""
        guard documentPath.lowercased().hasSuffix(".pdf"),
              let url = URL(string: documentPath).flatMap({ $0.isFileURL ? $0 : nil })
                  ?? (documentPath.hasPrefix("/") ? URL(fileURLWithPath: documentPath) : nil)
        else { return false }

        // Visible page from the window title, while we're on main with AX
        var titleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        let startPage = (titleRef as? String).flatMap(PagedText.previewPage(fromTitle:)) ?? 1

        fputs("[keyboard] R: PDF \(url.lastPathComponent), starting page \(startPage)\n", stderr)
        DispatchQueue.global(qos: .utility).async { [self] in
            let loaded = PagedText.load(url: url)
            DispatchQueue.main.async { [self] in
                guard let loaded else {
                    Earcon.error()
                    onAnnounce?("No readable document here.")
                    return
                }
                onSpeakPaged?(loaded.paged, startPage, loaded.headings)
            }
        }
        return true
    }

    /// The `r` command: triple-click selects the paragraph under the
    /// pointer, then read the selection. Shared by the NORMAL dispatch and
    /// the READING capture — r mid-read is a clear "read that instead", and
    /// the new speak() replaces the current utterance seamlessly (stale
    /// didCancel: media stays ducked, capture stays engaged).
    private func readAtPointer() {
        DispatchQueue.main.async { [self] in
            tripleClickAtCursor()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
                Self.readSelection { [self] text in onSpeakDocument?(text, 0) }
            }
        }
    }

    // MARK: - Triple Click

    private func tripleClickAtCursor() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let pos = CGEvent(source: nil)?.location ?? .zero

        for clickCount: Int64 in 1...3 {
            guard let down = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: pos,
                mouseButton: .left
            ), let up = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: pos,
                mouseButton: .left
            ) else { return }

            down.setIntegerValueField(.mouseEventClickState, value: clickCount)
            down.post(tap: .cghidEventTap)

            up.setIntegerValueField(.mouseEventClickState, value: clickCount)
            up.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Visual follow (the view tracks the read)

    /// Master switch (`:config follow`, keyboard.follow). Gates both the
    /// Preview go-to-page gesture and web scroll-follow.
    var followEnabled = true

    /// Go-to-page keyboard gestures per PDF viewer. v1 ships Preview
    /// (Cmd+Option+G opens its Go to Page sheet); other viewers join once
    /// their chords — and AXDocument exposure — are verified on hardware.
    struct PageChord {
        let keycode: CGKeyCode
        let command: Bool
        let option: Bool
        let shift: Bool
    }
    static let pageChords: [String: PageChord] = [
        "com.apple.Preview": PageChord(keycode: 5, command: true, option: true,
                                       shift: false),  // Cmd+Option+G
    ]

    /// Fire the viewer's go-to-page gesture: chord, pause for the sheet,
    /// digits, Return. Marker-tagged synthetic events pass our own tap
    /// even during READING capture. Fire-and-forget — a missed gesture
    /// never disturbs the read.
    func postGoToPage(_ page: Int, chord: PageChord) {
        guard followEnabled else { return }
        postKey(keycode: chord.keycode, shift: chord.shift,
                command: chord.command, option: chord.option)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            for code in Self.digitKeycodes(page) { postKey(keycode: code) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                postKey(keycode: 36)  // Return
            }
        }
    }

    /// ANSI number-row keycodes for a page number's digits, typing order.
    static func digitKeycodes(_ n: Int) -> [CGKeyCode] {
        let keys: [Character: CGKeyCode] = ["0": 29, "1": 18, "2": 19, "3": 20,
                                            "4": 21, "5": 23, "6": 22, "7": 26,
                                            "8": 28, "9": 25]
        return String(max(0, n)).compactMap { keys[$0] }
    }

    // Web scroll-follow: anchors[i] = the AX element that contributed line
    // i of the harvested article. As the read position crosses lines, the
    // contributing element is asked to scroll itself visible — Reader
    // articles track the voice like Firefox's own Narrate. Preprocessing
    // can drop the odd line, so the index is clamped: ±1 paragraph drift
    // is invisible at scroll granularity.
    private var webReadAnchors: [AXUIElement] = []
    private var followAnchorIndex = -1
    private var followLastScroll = Date.distantPast
    private var followScrollBroken = false

    func setWebReadAnchors(_ anchors: [AXUIElement]) {
        webReadAnchors = anchors
        followAnchorIndex = -1
        followLastScroll = .distantPast
        followScrollBroken = false
    }

    func clearWebReadAnchors() {
        webReadAnchors = []
    }

    /// Read position moved (Daemon relays SpeechEngine.onPositionChange
    /// with the processed read text). Main queue, NEVER the tap callback —
    /// the scroll is a synchronous AX call.
    func followScroll(offset: Int, text: String) {
        guard followEnabled, !webReadAnchors.isEmpty, !followScrollBroken else { return }
        let line = Self.lineIndex(of: offset, in: text)
        let anchorIndex = max(0, min(line, webReadAnchors.count - 1))
        guard anchorIndex != followAnchorIndex,
              Date().timeIntervalSince(followLastScroll) >= 0.8 else { return }
        followAnchorIndex = anchorIndex
        followLastScroll = Date()
        let element = webReadAnchors[anchorIndex]
        AXUIElementSetMessagingTimeout(element, 0.25)
        let err = AXUIElementPerformAction(element, "AXScrollToVisible" as CFString)
        if err != .success {
            // One log line, then stop trying for this read — support for
            // the action is per-app and a dead one mustn't cost an AX
            // round-trip every paragraph
            followScrollBroken = true
            fputs("[keyboard] follow: scroll action unsupported (\(err.rawValue))\n", stderr)
        }
    }

    /// Newlines before `offset` — the line index the voice is on.
    static func lineIndex(of offset: Int, in text: String) -> Int {
        let ns = text as NSString
        let end = max(0, min(offset, ns.length))
        var count = 0
        var i = 0
        while i < end {
            if ns.character(at: i) == 0x0A { count += 1 }
            i += 1
        }
        return count
    }

    // MARK: - Synthetic Key Posting

    /// Post a synthetic key event (for visual mode selection).
    /// Tagged with syntheticMarker so our event tap passes them through.
    private func postKey(keycode: CGKeyCode, shift: Bool = false, command: Bool = false,
                         option: Bool = false, count: Int = 1) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        var flags: CGEventFlags = []
        if shift { flags.insert(.maskShift) }
        if command { flags.insert(.maskCommand) }
        if option { flags.insert(.maskAlternate) }

        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: false) else { continue }
            down.flags = flags
            down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            down.post(tap: .cghidEventTap)

            up.flags = flags
            up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            up.post(tap: .cghidEventTap)
        }
    }

    // MARK: - AX-Based Visual Selection

    private static func tryCreateVisualAXState() -> VisualAXState? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Don't let a hung app stall us for the 6-second default AX timeout
        AXUIElementSetMessagingTimeout(axApp, 0.5)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success,
              let focused = focusedRef,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.5)

        // Must support settable selection range
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            element, kAXSelectedTextRangeAttribute as CFString, &settable
        ) == .success, settable.boolValue else { return nil }

        // Get current insertion point
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success,
              let rangeVal = rangeRef,
              CFGetTypeID(rangeVal) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeVal as! AXValue, .cfRange, &range) else { return nil }

        // Get text content for line navigation
        var textRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &textRef
        ) == .success, let text = textRef as? String else { return nil }

        let position = range.location + range.length
        fputs("[keyboard] AX visual: position=\(position), textLength=\(text.count)\n", stderr)
        return VisualAXState(element: element, text: text as NSString, anchor: position, cursor: position)
    }

    private enum AXMotionDirection { case left, right, up, down, toEnd }

    private func axMotion(_ direction: AXMotionDirection, count: Int) {
        guard var state = visualAXState else { return }
        let length = state.text.length

        switch direction {
        case .left:
            state.cursor = max(0, state.cursor - count)
        case .right:
            state.cursor = min(length, state.cursor + count)
        case .down:
            var pos = state.cursor
            for _ in 0..<count {
                let remaining = NSRange(location: pos, length: length - pos)
                let nl = state.text.range(of: "\n", range: remaining)
                if nl.location != NSNotFound {
                    pos = nl.location + 1
                } else {
                    pos = length
                    break
                }
            }
            state.cursor = pos
        case .up:
            var pos = state.cursor
            for _ in 0..<count {
                if pos == 0 { break }
                let searchRange = NSRange(location: 0, length: max(0, pos - 1))
                let nl = state.text.range(of: "\n", options: .backwards, range: searchRange)
                if nl.location != NSNotFound {
                    pos = nl.location
                } else {
                    pos = 0
                    break
                }
            }
            state.cursor = pos
        case .toEnd:
            state.cursor = length
        }

        visualAXState = state
        applyAXSelection()
    }

    private func axSelectCurrentLine() {
        guard var state = visualAXState else { return }
        let length = state.text.length
        let pos = state.cursor

        // Find start of current line
        var lineStart = 0
        if pos > 0 {
            let before = NSRange(location: 0, length: pos)
            let nl = state.text.range(of: "\n", options: .backwards, range: before)
            lineStart = nl.location != NSNotFound ? nl.location + 1 : 0
        }

        // Find end of current line (include newline)
        let after = NSRange(location: pos, length: length - pos)
        let nl = state.text.range(of: "\n", range: after)
        let lineEnd = nl.location != NSNotFound ? nl.location + 1 : length

        state.anchor = lineStart
        state.cursor = lineEnd
        visualAXState = state
        applyAXSelection()
    }

    private func applyAXSelection() {
        guard let state = visualAXState else { return }
        var start = min(state.anchor, state.cursor)
        var end = max(state.anchor, state.cursor)

        // For visual line mode, expand to full lines
        if mode == .visualLine {
            let text = state.text
            let length = text.length

            if start > 0 {
                let before = NSRange(location: 0, length: start)
                let nl = text.range(of: "\n", options: .backwards, range: before)
                start = nl.location != NSNotFound ? nl.location + 1 : 0
            }
            if end < length {
                let after = NSRange(location: end, length: length - end)
                let nl = text.range(of: "\n", range: after)
                end = nl.location != NSNotFound ? nl.location + 1 : length
            }
        }

        var range = CFRange(location: start, length: end - start)
        guard let rangeVal = AXValueCreate(.cfRange, &range) else { return }
        AXUIElementSetAttributeValue(state.element, kAXSelectedTextRangeAttribute as CFString, rangeVal)
    }

    /// Queue a visual-mode hjkl motion. The AX-vs-synthetic-key decision is
    /// made inside the block so it sees the visualAXState created by the
    /// (also queued) mode-entry block, even if the keys arrived back-to-back.
    private func extendSelection(_ direction: AXMotionDirection, arrowKeycode: CGKeyCode) {
        let count = max(1, pendingCount)
        pendingCount = 0
        visualDidExtendSelection = true
        DispatchQueue.main.async { [self] in
            if visualAXState != nil {
                axMotion(direction, count: count)
            } else {
                postKey(keycode: arrowKeycode, shift: true, count: count)
            }
        }
    }

    /// Collapse the visual selection (mode/count are reset by the caller
    /// inside the tap callback; this part does the slow AX/CGEvent work).
    private func collapseVisualSelection() {
        if let state = visualAXState {
            // Collapse selection to cursor position via AX
            var range = CFRange(location: state.cursor, length: 0)
            if let rangeVal = AXValueCreate(.cfRange, &range) {
                AXUIElementSetAttributeValue(state.element, kAXSelectedTextRangeAttribute as CFString, rangeVal)
            }
            visualAXState = nil
        } else if visualDidExtendSelection {
            postKey(keycode: 124) // Right arrow collapses selection
        }
        visualDidExtendSelection = false
    }

    // MARK: - Time / Date

    /// The wording lives in `BriefPlan.spokenClock` — pure, tested, and
    /// SHARED with the daily brief, so `t` and the brief can never drift
    /// into saying the time two different ways.
    private static func spokenTime() -> String {
        let cal = Calendar.current
        let now = Date()
        return BriefPlan.spokenClock(hour: cal.component(.hour, from: now),
                                     minute: cal.component(.minute, from: now))
    }

    private static func currentTime() -> String {
        spokenTime()
    }

    private static func currentTimeAndDate() -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM"
        return "\(spokenTime()), \(f.string(from: Date()))"
    }

    // MARK: - AX Selected Text

    /// Speak-the-selection with resilience: AX first, clipboard-copy
    /// fallback when AX fails or comes back empty. Huge selections (Cmd+A
    /// on a whole document) routinely exceed the 0.5s AX messaging timeout,
    /// and some apps never expose kAXSelectedTextAttribute at all — without
    /// the fallback those reads are silent no-ops. Shared by Option+Escape,
    /// normal-mode r (post triple-click), and visual r. Main queue only;
    /// `deliver` is called at most once, never with empty text.
    static func readSelection(_ deliver: @escaping (String) -> Void) {
        if let text = getSelectedText(), !text.isEmpty {
            fputs("[keyboard] speak selection (\(text.count) chars)\n", stderr)
            deliver(text)
            return
        }
        copySelectionAndRead { text in
            guard let text, !text.isEmpty else { return }
            fputs("[keyboard] speak selection via clipboard fallback (\(text.count) chars)\n", stderr)
            deliver(text)
        }
    }

    /// Fired once per session when AX calls start failing with
    /// kAXErrorAPIDisabled (-25211): the Accessibility grant broke (an
    /// update's re-sign is the usual culprit) while the already-created
    /// tap kept running — a uniquely confusing half-alive state.
    nonisolated(unsafe) static var onAXRevoked: (() -> Void)?
    private nonisolated(unsafe) static var axRevokedNoticed = false

    static func noteAXError(_ code: Int32) {
        guard code == -25211, !axRevokedNoticed else { return }
        axRevokedNoticed = true
        DispatchQueue.main.async { onAXRevoked?() }
    }

    static func getSelectedText() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Don't let a hung app stall us for the 6-second default AX timeout
        AXUIElementSetMessagingTimeout(axApp, 0.5)

        var focusedElement: CFTypeRef?
        let focusErr = AXUIElementCopyAttributeValue(
            axApp, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard focusErr == .success,
              let focused = focusedElement,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            if focusErr != .success {
                fputs("[keyboard] AX focused-element copy failed (\(focusErr.rawValue))\n", stderr)
                noteAXError(focusErr.rawValue)
            }
            return nil
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.5)

        var selectedText: CFTypeRef?
        let textErr = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &selectedText)
        guard textErr == .success else {
            // -1001 CannotComplete is the 0.5s timeout — typically a huge
            // Cmd+A selection; the clipboard fallback in readSelection
            // covers it
            fputs("[keyboard] AX selected-text copy failed (\(textErr.rawValue))\n", stderr)
            return nil
        }

        return selectedText as? String
    }

    // (The old macOS speak-under-pointer integration — the Ctrl+Option+
    // Cmd+P shortcut post, the media pause/resume dance, and the
    // isAudioOutputRunning device check — is gone: `s` now drives
    // Marduk's own HoverSpeech, which uses the reading voice and needs
    // neither Settings setup nor media pausing.)

    /// Fallback for apps where AX selected text isn't available (e.g. iMessage).
    /// Posts Cmd+C to copy selection, then reads from pasteboard.
    static func copySelectionAndRead(completion: @escaping (String?) -> Void) {
        let pb = NSPasteboard.general
        let oldCount = pb.changeCount

        // Post Cmd+C (keycode 8 = 'c')
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else {
            completion(nil)
            return
        }
        down.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        down.post(tap: .cghidEventTap)

        up.flags = .maskCommand
        up.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        up.post(tap: .cghidEventTap)

        // Wait for pasteboard to update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if pb.changeCount != oldCount, let text = pb.string(forType: .string) {
                fputs("[keyboard] clipboard fallback: got \(text.count) chars\n", stderr)
                completion(text)
            } else {
                completion(nil)
            }
        }
    }
}
