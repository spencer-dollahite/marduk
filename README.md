<p align="center">
  <img src="assets/logo.svg" width="128" alt="Marduk logo: a white letter M on a black rounded square">
</p>

<h1 align="center">Marduk</h1>

<p align="center"><strong>An audio-first, vim-style reading and navigation layer for macOS, built for low-vision users.</strong></p>

---

> [!WARNING]
> **Early alpha.** Marduk is a personal tool being opened up, not a finished product. It is built around one user's workflow, tested on exactly one machine, and things will break. **Do not depend on it as your only means of accessing your computer.** It is speech-only — there is **no braille support** — and it is **not a full screen reader**: if you rely on VoiceOver, keep VoiceOver.

## Who this is for

- **Low-vision users** who can see the screen but read by ear — people for whom VoiceOver is too much and macOS Spoken Content is too little.
- **Audio-first readers** who want "select something, hear it, keep your music sensibly out of the way" as a first-class workflow.
- **Keyboard and vim people** who want modal, home-row-driven control of speech without lifting their hands (or with a programmable mouse doing the reading).

## What it does

- **Vim-style modal keyboard layer** — NORMAL (commands), INSERT (typing), VISUAL / VISUAL LINE (select with `hjkl`, count prefixes like `3j`, read with `r`). A colored-earcon mode system, an escape tap/hold that never steals Escape from vim, and a *typing rescue* that notices when you type into NORMAL mode by mistake, flips to INSERT, and replays your keystrokes so nothing is lost.
- **Reading that respects your audio** — speech pauses your browser/system media (play/pause, only if it was actually playing) and volume-ducks Apple Music/Spotify, then puts everything back when the read ends. Speech and media never fight.
- **Pause and resume** — Space pauses an active read at a word boundary and resumes it; the moment nothing is being read, Space is just Space.
- **A speech preprocessor built for real content** — strips the invisible Unicode that makes TTS silently bail; speaks code symbols by name with configurable verbosity (`->` "arrow", `!=` "not equals"); collapses symbol runs ("5 dash" instead of dash-dash-dash-dash-dash); abbreviates hex digests ("md5 ending in 2 7 e" instead of 32 characters of hex).
- **Two voices** — one for reading content, one for status announcements, so you always know which is which.
- **A vim-style command line with a visual palette** — press `:` in NORMAL mode and a centered, dmenu-style panel opens, listing everything you can type with descriptions and current values, filtering as you go: `:help`, `:commands`, `:tutorial`, `:config rate 230`. The moment your typing is unambiguous it just goes — `:h` runs help, `:con` becomes `config` and moves on — no Enter needed except for numbers. Tab completes, arrows browse (spoken), rows are clickable, `?` — or just pausing — speaks your options, and `/` fuzzy-searches everything at once. Settings changed via `:config` apply instantly and persist.
- **A talking interactive tutorial** — `:tutorial` walks you through the modes vimtutor-style: it asks you to actually press the keys and confirms out loud when you get it. First run also greets you with a short spoken orientation.
- **Runs as a proper service** — a launchd agent starts Marduk at login, restarts it if it crashes, and logs to `~/Library/Logs/marduk.log`. Updates are spoken before they're installed: `u` fetches and reads the release notes aloud, `uu` installs (pull, build, codesign, restart), and a daily background check announces when something new is available (`:config autoupdate on` to install automatically, `:config checkhours 0` to disable checks).
- **Signed builds** — binaries are codesigned with your (free) Apple Development certificate so macOS Accessibility permission survives rebuilds.
- **No dependencies** — pure Swift and native Apple frameworks. No Electron, no Python, no network calls.

## Requirements

- macOS 26 (Tahoe), Apple Silicon
- Xcode (for the Swift toolchain **and** a free Apple Development signing certificate — without one, every rebuild invalidates the Accessibility grant)
- Optional: [Karabiner-Elements](https://karabiner-elements.pqrs.org/) if you want mouse-button reading triggers (a sample profile ships in `ke/`)

## Install

```bash
git clone https://github.com/spencer-dollahite/marduk.git
cd marduk
swift build
.build/debug/marduk install     # installs the launchd agent (autostart + crash restart)
```

Add `.build/debug` to your PATH or symlink the binary somewhere convenient; the commands below assume `marduk` resolves.

### Permissions (the important part)

Marduk is assistive technology: it needs deep hooks, and macOS makes you grant each one.

1. **Accessibility** — System Settings → Privacy & Security → Accessibility → **+** → press <kbd>Cmd+Shift+G</kbd> and enter the *resolved* binary path:
   `<repo>/.build/arm64-apple-macosx/debug/marduk`
   (not the `.build/debug` symlink — the permission is tied to the real file). If the grant is missing or broken, Marduk **tells you out loud** and re-checks every 10 seconds — no restart needed after you fix it. If a rebuild ever breaks the grant (it shouldn't once builds are signed), remove the entry and re-add it; toggling is not enough.
2. **Automation** — the first time speech ducks your media, macOS will ask permission for Marduk to control System Events / Music / Spotify. Allow them.
3. Sign in to Xcode once (Settings → Accounts) so a free "Apple Development" certificate exists in your keychain; `marduk update` and `marduk install` sign builds with it automatically.

## Usage

### CLI

| Command | What it does |
|---|---|
| `marduk install` / `uninstall` | Install/remove the launchd agent (login autostart, crash restart, log file) |
| `marduk start` / `stop` / `status` | Control and inspect the daemon (status shows daemon, agent, launchd state, log) |
| `marduk start --foreground [--debug]` | Run inline in a terminal for debugging |
| `marduk update` | Git pull + build + codesign + hot-restart (run from the repo) |
| `marduk speak "text"` / `--stdin` | Speak text (forwards to the daemon if running) |
| `marduk config` / `config rate <wpm>` | Show config / set speech rate (50–360 WPM) |
| `marduk voices` / `voices --test` | List / interactively audition TTS voices |
| `marduk audio-debug` | Dump audio-producing processes + Firefox tab tree |

### Keyboard

> **Start here: press `:` (Shift+;) in NORMAL mode.** The command palette opens, showing — and speaking — everything Marduk can do: help, the interactive tutorial, every setting with its current value. Type until your choice is unambiguous and it runs itself; `/` fuzzy-searches everything. You never have to memorize the reference below.

**Always active:** `Ctrl+Option+M` toggles Marduk on/off · `Option+Escape` speaks the current selection, or stops speech if speaking.

**Space (NORMAL/VISUAL):** pauses/resumes an active read — but only while something is actually being read; otherwise it's a normal Space, and in INSERT mode it is *always* a normal space. `Escape` cancels a paused read, freeing Space immediately.

**NORMAL mode** (default): `i` → INSERT · `v` / `V` → VISUAL / VISUAL LINE · `r` selects the paragraph under the cursor (like a triple-click) and reads it · `t` speaks the time (`tt` = time + date) · `s` toggles macOS speak-under-pointer · `u` speaks available updates, `uu` (or `u` again within a minute) installs them · `Escape` stops speech. Letters you type by mistake trigger the typing rescue (see above); numbers, arrows, and Cmd/Ctrl shortcuts always pass through.

**INSERT mode:** everything passes to the app. *Tap* Escape and the app gets it (vim keeps its Escape); *hold* Escape (~400 ms, configurable) to return to NORMAL.

**VISUAL / VISUAL LINE:** `hjkl` extend the selection (with count prefixes: `v3j`), `G` to end, `r` reads the selection and returns to NORMAL, `Escape` cancels.

**COMMAND mode (`:`):** type `:` in NORMAL for a vim-style command line with a floating palette showing your options. `:help` speaks the basics, `:commands` the full reference, `:tutorial` starts the guided tour, `:tip` speaks a random feature tip, `:quit` / `:restart` control the daemon, `:update` installs updates, `:uninstall` removes the launch agent, `:log` opens the log, `:feedback` / `:bug` open GitHub issues, and `:config <setting> <value>` changes settings live — `rate` (50–360 wpm), `level` (`none`/`some`/`most`/`all`), `hashes`, `rescue`, `burst`, `escapehold`, `echo` (speak keys as you type, off by default), `commandecho`, `palette` (all `on`/`off` or a number). Unique prefixes work everywhere (`:conf ra 230`); Tab completes; `?` or a moment's pause speaks what you can type next; Escape cancels.

### Configuration

`~/.config/marduk/config.json` (auto-created with defaults):

- `speech` — rate, voice identifier
- `ducking` — duck level, ramp, per-app targets, media-key pause on/off
- `keyboard` — escape hold threshold, typing-rescue window, rescue on/off
- `verbalizer` — symbol verbosity (`none`/`some`/`most`/`all`), per-symbol overrides (`{"*": "asterisk", "%": ""}`), hash abbreviation on/off
- `update` — periodic check interval in hours (0 = off), auto-install on/off
- `display` — per-app color inversion list

Config is read at daemon start. Most settings can be changed live from inside Marduk with `:config` (which also saves them); if you hand-edit the file instead, restart (or `marduk update`) to apply.

## Known quirks (read before filing bugs)

These are deliberate trade-offs of the typing-rescue system, not bugs:

- **Words starting with "i" lose their leading i** if you type them in NORMAL mode — `i` enters INSERT instantly (so `i`-then-type works), which means typing "is" in NORMAL becomes INSERT + "s". The falling earcon tells you it happened.
- **Single-letter commands fire ~300 ms late** (`r`, `t`, `s`, `u` alone) — that's the typing-rescue window deciding you weren't typing a word. `v`+motion and `i` are instant. Set `keyboard.typingRescue: false` to make all commands instant at the cost of the rescue (and of `tt`).
- **A command followed quickly by `k` reads as typing** — protects words like "skip".
- **Short reads pause your media briefly** even for a two-word utterance — pause/resume is deliberate (volume-ducking a browser can't stop a video, and lowering system volume would quiet Marduk itself).
- Hand-edits to config.json need a daemon restart — use `:config` from inside Marduk (or `marduk config rate`) for live changes.

## How it works

A background daemon (no UI) built on the C-level `AXUIElement` accessibility API, `CGEventTap` for the modal keyboard layer, `AVSpeechSynthesizer` for speech, and CoreAudio + AppleScript for media-aware ducking — the same primitives VoiceOver-class tools use, since Apple ships no third-party screen-reader SDK. Architecture notes live in [CLAUDE.md](CLAUDE.md) and the long-form design in [PLAN.md](PLAN.md).

## Roadmap (rough, no promises)

- Accessibility-tree navigation (element-wise `hjkl`, headings/links quick-nav)
- OCR fallback for inaccessible apps (Vision framework)
- Spatial/earcon audio themes
- Firefox Reader Mode auto-activation
- Speech rate keys, repeat-last-utterance, richer mode announcements

Explicitly **out of scope**: braille, and full screen-reader parity with VoiceOver/NVDA.

## Contributing

Issues, bug reports, and "this assumption doesn't survive contact with my setup" reports are very welcome — especially from low-vision users. This is a personal project maintained at personal-project pace; PRs are welcome but may sit.

**When filing bugs:** your `~/Library/Logs/marduk.log` contains snippets of text Marduk has spoken (your emails, messages, articles) — redact before pasting.

If Marduk is useful to you, you can [sponsor development](https://github.com/sponsors/spencer-dollahite).

## License

[MIT](LICENSE) © Spencer Dollahite
