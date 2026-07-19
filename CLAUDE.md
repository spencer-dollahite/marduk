# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Marduk

Marduk is an assistive technology platform for macOS (targeting macOS 26) that replaces VoiceOver. It combines native Apple Accessibility APIs, spatial audio, and Karabiner Elements with Vim-style modal navigation. It runs as a background daemon with no UI — all configuration is via files and CLI.

## Build & Run

```bash
swift build                          # Build (output: .build/debug/marduk)
marduk start                         # Start daemon (via launchd if installed, else foreground)
marduk start --foreground [--debug]  # Run inline in the terminal (needs Accessibility permission)
marduk stop                          # Stop daemon (stays stopped; agent restarts it at next login)
marduk install                       # Install launchd agent: login autostart + crash restart
marduk uninstall                     # Remove the launchd agent
marduk status                        # Daemon / agent / launchd / log status
marduk update                        # Git pull + build + hot-reload (run from project dir)
marduk speak "text"                  # Speak text (forwards to daemon if running, else inline)
marduk speak --debug "text"          # Speak with ducking debug logs
marduk config                        # Show config JSON
marduk config rate <50-360>          # Set speech rate in WPM
marduk voices --test                 # Interactive voice tester
```

No external dependencies — pure Swift Package Manager with native Apple frameworks only.

## Architecture

```
main.swift (CLI argument parser)
  ↓
DaemonServer (Unix socket IPC at /tmp/marduk.sock)
  ├── SpeechEngine (AVSpeechSynthesizer — dual voices: reading + announcement)
  │   └── AudioDucker (probes playback state, ducks external audio during speech)
  └── KeyboardMonitor (CGEventTap — Vim modal: NORMAL/INSERT)
```

**Threading model:** Main thread runs RunLoop for AVSpeechSynthesizer callbacks + CGEventTap. Socket accept runs on background DispatchQueue. AudioDucker operations serialize on its own queue. AppleScript calls are synchronous via `Process`.

**IPC protocol:** Text-based commands over Unix socket (e.g., `speak Hello`, `rate 0.5`, `ping` → `OK pong`). `DaemonClient.send()` is synchronous request-response.

**Config:** `~/.config/marduk/config.json` — `MardukConfig` (Codable) with ducking, speech, display, keyboard, and verbalizer settings. `ConfigLoader` auto-creates defaults on first run. Speech/keyboard/verbalizer settings apply LIVE via `:config <key> <value>` (DaemonServer retains `config`, mutates, saves); hand-editing the file still requires a restart. **Adding fields:** new keys inside existing blocks (and new top-level blocks) must be declared Optional and defaulted at the consumption site with `??` — a required key missing from the user's existing config.json fails the whole decode, and `ConfigLoader.load()` responds to a failed decode by silently resetting the file to defaults, wiping the user's voice/rate settings.

## Key Patterns

- **Logging:** `fputs("[component] message\n", stderr)` — components: `[speech]`, `[ducker]`, `[keyboard]`, `[marduk]`, `[update]`, `[main]`, `[display]`, `[earcon]`, `[verbalizer]`, `[agent]`, `[sign]`, `[command]`, `[tutorial]`, `[bundle]`
- **Sendable workarounds:** `@unchecked Sendable` classes with `nonisolated(unsafe)` for AV framework types
- **Callbacks:** `onEvent` pattern (onSpeak, onStop, onAnnounce, onWordBoundary); speech chaining uses the per-utterance `completion:` parameter of `speak`/`announce`
- **Enums as namespaces:** `Earcon`, `DaemonClient`, `ConfigLoader`, `MardukDaemon` are caseless enums with static members
- **AppleScript execution:** Via `Process` + `/usr/bin/osascript`, three variants: `runAppleScript` (→ Int?), `runAppleScriptString` (→ String?), `runAppleScriptSync` (fire-and-forget)
- **Key suppression:** In NORMAL mode, alpha keys are withheld by the typing-rescue burst buffer (~300ms) and then either executed as commands, beeped, or replayed into the app as typing — except `k`, which passes straight through, and `i`, which enters INSERT instantly. Space, numbers, arrows, function keys pass through (but see Space pause/resume below). Cmd/Ctrl combos always pass through. With `keyboard.typingRescue: false`, alpha keys are consumed immediately (pre-rescue behavior).

## Speech Preprocessing (Sanitizer + Verbalizer)

`SpeechPreprocessor` (Sources/Audio/SpeechPreprocessor.swift) runs inside `SpeechEngine.speak()` on every read: **sanitize** (strips control chars, invisible Unicode — ZWSP/BOM/variation selectors/directional marks — private-use chars; emoji ZWJ sequences survive; NBSP → space) → **hash abbreviation** (word-bounded all-hex runs at standard digest lengths — 32/40/64/128 → md5/sha1/sha256/sha512, named by length convention — collapse to "md5 ending in 2 7 e"; requires ≥1 digit and ≥1 letter so numeric IDs don't mislabel; runs at every level, `verbalizer.hashes: false` disables) → **verbalize** (speaks symbols as words per `verbalizer.level`: `none`/`some`/`most`/`all`, default `most` = code symbols spoken, prose punctuation left to natural pausing; digraphs like `->` "arrow" and `!=` "not equals"; symbol runs ≥3 collapse to "N name" using the full symbol table even for symbols unspoken at the level — `-----` says "5 dash" at most; a bare `...` stays raw below `all` (natural ellipsis pause); unnamed symbols cap at 3 raw) → **whitespace normalize**. Sanitize is the anti-bail stage and runs at every level. Empty-after-processing skips speaking but still fires the `completion:` (the inline CLI blocks on it). `announce()` gets sanitize only. Config: `verbalizer` block — `level`, plus `symbols` overrides (`{"*": "asterisk", "->": "maps to", "%": ""}`; empty string silences a symbol). Config is read at daemon init; `:config level|hashes` rebuilds the preprocessor live, while hand-edits to the file still require a restart. Tests: `swift test` (Tests/MardukTests, macOS only).

## Audio Ducking Flow

`prepareToDuck()` (before speech) → probes the CoreAudio-based mediaKey state synchronously (so our own speech can't contaminate it), stores it on the ducker queue → `duck()` (async, on didStart) → uses cached state, probes Apple Music/Spotify via AppleScript on the ducker queue (never on the main thread), only pauses what's actually playing → `unduck()` (async, on didFinish/didCancel) → only restores what was ducked. `audioProducingPIDs()` filters out our own PID AND Apple's speech-synthesis service process (enhanced voices render there — without the filter, back-to-back reads mistake draining speech audio for playing media). All osascript runs have a kill-on-timeout watchdog so a hung System Events can't wedge the ducker queue.

**Important:** Never use fixed delays to wait for speech to finish. Pass a `completion:` to `speech.speak`/`speech.announce` to chain actions after speech completes — this ensures unduck() has time to restore media before the next action. Completions are tracked per-utterance (fired on finish or cancel, only for their own utterance), so a replaced utterance can never fire or clear its successor's callback. Only the current utterance's end unducks; stale didCancel deliveries are ignored.

## Keyboard Modal System

- **NORMAL** (default): Commands active, letter keys suppressed. `s` posts Ctrl+Option+Cmd+P to toggle macOS "Speak items under pointer" (requires one-time shortcut assignment in System Settings > Keyboard > Keyboard Shortcuts > Accessibility).
- **Typing rescue** (NORMAL): unmodified letter keyDowns are withheld ~300ms (`keyboard.typingBurstMs`; `keyboard.typingRescue: false` disables) instead of executing immediately. A quick burst containing a non-command letter means the user forgot the mode and is typing — auto-switch to INSERT, play a falling sweep (`Earcon.fallToInsert`), and replay the withheld keys synthetically as down+up pairs (marker-tagged, in order — pairs because the real keyUps usually passed through before the replay posts; a replay-rollover guard swallows and re-queues keys typed during the switch so nothing reorders). All-command bursts (`s` then `r`) execute as commands on timer expiry via recursive redispatch through `handleEvent` (mode-aware: a buffered `i` flips to INSERT and later buffered keys get typed, not executed). Consequences: single letter commands fire ~300ms late; `i` on an empty buffer is instant (the i-then-type flow); `v`+motion (`vj`, `v3j`) flushes immediately and stays instant; `tt` resolves on the second t (commands buffered before the pair flush first); words starting with `i` lose their leading i; a command followed quickly by `k` reads as typing (words like "skip" must rescue); with rescue disabled there is no `tt` (each `t` speaks time immediately).
- **INSERT** (`i`): Entry always plays `Earcon.fallToInsert` (explicit `i` and typing rescue sound identical). All keys pass through. Escape is tap/hold: a tapped Escape is delivered to the app on key release (synthetic re-post — vim/Claude Code keep their Escape); holding it past the threshold (default 400ms, `keyboard.escapeHoldMs` in config) returns to NORMAL and plays a rising sweep (`Earcon.riseToNormal`) — the app never sees a held Escape. The withheld press is flushed early if another key rolls over it, so fast Esc+j typing stays ordered. Modified Escapes (Cmd/Ctrl/Shift) pass through untouched.
- **VISUAL** (`v`): Character-wise selection with hjkl, `r` reads selection. Entry is spoken ("visual"/"visual line"); exit via Escape/`v` plays `Earcon.riseToNormal` (`r` exits silently — the read is the feedback)
- **VISUAL LINE** (`V`): Line-wise selection, auto-selects current line on entry
- **COMMAND** (`:` = Shift+; in NORMAL): vim-style command line, driven entirely by the event tap. Chars append to `commandBuffer` (keycode→char via `commandKeyChars`; echo per char when `commandEcho`), Return submits via `onCommandSubmit` (empty = cancel), Escape cancels, Delete edits (exits on empty buffer), Tab autocompletes to the palette selection via `onCommandTab`→`replaceCommandBuffer`, Up/Down move the selection, `?` speaks the current options, a ~1.5s typing pause speaks them automatically (`onCommandIdle`; silent when none), and `/` on an empty buffer starts an fzf-style FUZZY SEARCH over the whole catalog (commands + config keys; greedy-subsequence `fuzzyScore`, lower = tighter; Return accepts the selection — commands execute, keys expand into the value stage; `/` buffers never auto-resolve). Cmd/Ctrl AND Option combos pass through (the user's zoom shortcuts ride on Option — command mode must never eat them), as do unmapped non-typing keys (F-keys, keypad, custom codes); only unmapped typing-shaped keys (`typingPunctuationKeys`) buzz, logging the keycode. Autorepeat suppressed except Delete/arrows. Commands (unique-prefix expanded, vim-style — `:conf ra 230` works): `:help`/`:h`, `:commands`/`:c`, `:tutorial` (toggles the interactive tour — Tutorial.swift watches real mode/read/pause events), `:tip` (random feature tip from HelpText.tips, no immediate repeats), `:config`/`:set <key> <value>` (live apply + persist). **Auto-accept (dmenu semantics):** ~350ms after the last typed char (`ColonCommand.autoResolve`, debounced in `handleCommandChange` so fast full-word typing is never cut off), an unambiguous buffer acts without Enter — argless commands and unique enum values execute, `config`/keys expand and advance; numbers always need Enter; deletions never auto-accept (canAutoAccept flag on `onCommandChange`), or removing an auto-added space would re-add it. Settings table lives in `ColonCommand.settings` (shared by parser, palette, and validation). The **command palette** (Sources/Display/CommandPalette.swift, gated by `keyboard.commandPalette`) is a dmenu-style panel whose INPUT still comes from the event tap — it renders the buffer + candidates from `CommandCompleter` — but it TAKES key focus while open (Spotlight-style: remembers `NSWorkspace.frontmostApplication`, `NSApp.activate()`, `makeKeyAndOrderFront`; borderless panels need the `canBecomeKey` override) and reactivates the previous app on hide. Position is configurable (`keyboard.palettePosition` / `:config position center|pointer`): `center` (default) is fully centered on the pointer's screen; `pointer` opens at the cursor, which is the ONLY zoom-proof placement — macOS fullscreen zoom pans exclusively on hardware pointer deltas (warps, synthetic mouseMoved posts, and interpolated glides were all tried and verified NOT to pan it; no viewport API exists — the old border overlay's lesson), but zoom always keeps the real cursor in view, so at-pointer is inside the viewport by definition. The prompt line is a REAL focused `NSTextView` (PromptTextView — keyDown/insertText swallowed, the tap owns input) with a genuine blinking caret, so zoom's follow-focus/text-insertion modes track the palette natively via AX notifications; level is `.floating`, NOT `.screenSaver` (the aggressive level broke zoom state while open); rows are mouse-clickable (click = Tab on that row, `onRowClick`). With the palette off, command mode is pure audio and steals nothing. `DaemonServer.run()` initializes `NSApplication.shared` (`.accessory`) for it.
- **Always-active:** Ctrl+Option+M toggles Marduk, Option+Escape speaks selection/stops speech
- **Space (read pause/resume):** while a content read is speaking or paused (`SpeechEngine.readActive` — announcements excluded), unmodified Space in NORMAL/VISUAL pauses at a word boundary / resumes, and never reaches the app. In INSERT, Space is always a real space, even mid-read. Otherwise Space types/passes as normal. A typing-rescue burst in flight wins over pause (user is typing). Escape in NORMAL cancels a paused read (a paused synthesizer still reports `isSpeaking`), freeing Space back to normal. Media stays ducked/paused across a speech pause — only the read's end or Escape (stop) unducks. `readActive` is plain stored state so the tap callback can read it synchronously (no AV query in the callback).
- **macOS keycodes:** `s`=1, `t`=17, `i`=34, `u`=32, `r`=15, Escape=53, `m`=46, Space=49
- **Double-tap `t`/`tt` (time/date):** resolved by the typing-rescue burst buffer (second `t` within the burst window → time+date immediately; lone `t` → time on burst-timer expiry)
- **Updates (`u`/`uu`):** lone `u` fetches origin/main off-main and speaks the commit subjects since the running build ("release notes"), arming a 60s window; `u` again while armed — or `uu` in the burst window, resolved like `tt` — installs via `performUpdate`. A periodic timer (`update.checkHours`, default 24, 0 = off; first check ~2min after start) does the same fetch: with `update.auto` on it installs, otherwise it announces once per new remote head (`lastAnnouncedRemote`). `:config autoupdate/checkhours` change both live.
- **Synthetic key events:** Visual mode posts Shift+Arrow keys (tagged with `eventSourceUserData` marker so our event tap passes them through)
- **Count prefix:** Visual mode accepts digits before motions (e.g. `3j` = select 3 lines down)
- **Autorepeat:** One-shot commands (i, u, v, r, t, s, Escape, Option+Escape, Ctrl+Option+M) ignore key autorepeat — a held Option+Escape's repeat would otherwise stop the read it just started. Visual motions (hjkl, G, digits) do repeat.
- **Event tap hygiene:** Never do blocking work (AX calls, Process launches, sleeps) inside the tap callback — AX is synchronous IPC with a long default timeout, and a slow callback gets the tap disabled by macOS, leaking suppressed keys into apps. Dispatch to the main queue instead (ordering is preserved). AX helpers set a 0.5s messaging timeout. A 5s watchdog timer re-enables the tap if macOS disabled it. If tap creation fails (missing Accessibility grant — e.g. under launchd, where permissions aren't inherited from a terminal), the failure is announced aloud and creation is retried every 10s, so granting the permission heals a running daemon.

## Running as a Service (launchd)

`Bundler` (Sources/App/Bundler.swift, `[bundle]` tag) assembles `<repo>/Marduk.app` on the Mac at install/update time — Info.plist via PropertyListSerialization, the M icon DRAWN IN CODE (CoreGraphics, same path as assets/logo.svg, iconutil-packed; failure = iconless bundle, non-fatal), binary copied in, bundle signed, then ATOMIC SWAP (`Marduk.app.new` → aside → in; never modify the live bundle in place — a running daemon keeps its inode). **Identity trio, keep identical:** launchd label == `Codesign.identifier` == CFBundleIdentifier == `com.marduk.daemon` (identical designated requirement is what can carry TCC grants across the bare-binary→bundle migration). `LSUIElement` keeps it out of the Dock. Bare-binary operation (`start --foreground` debugging, binary copied out of the repo) still works everywhere — bundle-ness is detected, never assumed. SMAppService adoption = future work.

**Migration (bare binary → bundle):** detected by `LaunchAgent.installedProgramPath() != bundleExec`. The CLI update rebootstraps synchronously (safe — it isn't the daemon). The daemon-side `uu` CANNOT bootout itself (deadlock: launchd waits for our exit while we wait for launchctl) — it writes the new plist FILE only, spawns `LaunchAgent.relaunchDetached()` (a `/bin/sh` helper via `posix_spawn` + `POSIX_SPAWN_SETSID` — mandatory, because the OLD plist lacks `AbandonProcessGroup` and launchd SIGKILLs the daemon's process group on exit), announces the one-time migration (even on the silent auto-update path), and exits CLEAN (0) so KeepAlive can't race-relaunch the old path before the helper's bootout→bootstrap→kickstart lands. New plists carry `AbandonProcessGroup: true`.

`LaunchAgent` (Sources/App/LaunchAgent.swift) manages a per-user LaunchAgent: label `com.marduk.daemon`, plist at `~/Library/LaunchAgents/com.marduk.daemon.plist`, stderr/stdout to `~/Library/Logs/marduk.log` (truncated on install/start if >10 MB; no rotation). The plist runs `Marduk.app/Contents/MacOS/marduk start --foreground` so launchd supervises the daemon process directly. `KeepAlive = {SuccessfulExit: false}`: crash or non-zero exit → relaunch (launchd throttles rapid loops ~10s); clean exit 0 (`marduk stop`) stays stopped until next login or `marduk start`. When the agent is installed: `start` kickstarts the service (re-bootstrapping if needed), `update` (CLI) kickstarts instead of spawning, and the daemon-side `u` hot-update exits with code 75 after clean teardown so launchd relaunches the freshly built binary — a `Process` spawn would be unsupervised. `marduk start` exits 0 when the daemon is already running: under KeepAlive a non-zero exit from the agent-spawned instance would relaunch-loop. **TCC / signing:** install and both update paths sign the assembled BUNDLE (`Codesign.sign(bundleAt:)` — one call on the staging .app seals the nested executable; only ever called on `Marduk.app.new`, so no in-place hazard; `sign(binaryAt:)` remains for the bare-binary fallback and keeps its copy-sign-swap). Identity is certificate + `com.marduk.daemon`, now also the CFBundleIdentifier — the grant is bundle-anchored and survives rebuilds. If no keychain identity exists, signing is skipped with a loud log (plain `swift build` also skips assembly/signing — deploy via `marduk update`). If the tap dies after an update anyway, the daemon announces it and re-adding the Accessibility entry (pick `Marduk.app` in the file dialog) heals it live.

## Runtime Files

- `/tmp/marduk.sock` — daemon IPC socket
- `/tmp/marduk.pid` — daemon PID file
- `~/.config/marduk/config.json` — user configuration
- `~/Library/LaunchAgents/com.marduk.daemon.plist` — launch agent (when installed)
- `~/Library/Logs/marduk.log` — daemon log (when running under launchd)
- `<repo>/Marduk.app` — assembled bundle (gitignored; rebuilt by install/update)

## Permissions Required

Accessibility (CGEventTap + AXUIElement), Automation (AppleScript to Music/Spotify/System Events). Future: Screen Recording, Input Monitoring.
