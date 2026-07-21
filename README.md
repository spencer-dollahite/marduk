<p align="center">
  <img src="assets/logo.svg" width="128" alt="Marduk logo: a white letter M on a black rounded square">
</p>

<h1 align="center">Marduk</h1>

<p align="center"><strong>An audio-first, vim-style reading and navigation layer for macOS, built for low-vision users.</strong></p>

<p align="center"><a href="https://github.com/spencer-dollahite/marduk/actions/workflows/ci.yml"><img src="https://github.com/spencer-dollahite/marduk/actions/workflows/ci.yml/badge.svg" alt="CI status"></a></p>

<h3 align="center"><a href="https://github.com/spencer-dollahite/marduk/releases/latest/download/Marduk.dmg">⬇&nbsp;&nbsp;Download Marduk</a></h3>
<p align="center">Latest release, signed &amp; notarized — open the .dmg, drag Marduk into Applications, follow the voice.</p>

---

> [!WARNING]
> **Early alpha.** Marduk is a personal tool being opened up, not a finished product. It is built around one user's workflow, tested on exactly one machine, and things will break. **Do not depend on it as your only means of accessing your computer.** It is speech-only — there is **no braille support** — and it is **not a full screen reader**: if you rely on VoiceOver, keep VoiceOver.

## Who this is for

- **Low-vision users** who can see the screen but read by ear — people for whom VoiceOver is too much and macOS Spoken Content is too little.
- **Audio-first readers** who want "select something, hear it, keep your music sensibly out of the way" as a first-class workflow.
- **Keyboard and vim people** who want modal, home-row-driven control of speech without lifting their hands (or with a programmable mouse doing the reading).

## Install

All you need is an **Apple Silicon Mac running macOS 26 (Tahoe)**. Optional: [Karabiner-Elements](https://karabiner-elements.pqrs.org/) if you want mouse-button reading triggers (a sample profile ships in `ke/`).

1. **[Download Marduk.dmg](https://github.com/spencer-dollahite/marduk/releases/latest/download/Marduk.dmg)** (that link is always the latest release) and open it.
2. Drag **Marduk** into **Applications**.
3. Open Marduk. It installs itself, starts talking, and opens the right Settings pane for the one permission it needs — follow the voice.

Or with [Homebrew](https://brew.sh):

```sh
brew install --cask spencer-dollahite/marduk/marduk
```

then open Marduk from Applications as in step 3. `brew upgrade` brings future releases.

Releases are signed and notarized — no Xcode, no Terminal, no warnings from macOS. Updates for release installs come from the same Releases page or `brew upgrade` (press `u` and Marduk will remind you); in-app updating for release installs is planned.

<details>
<summary><strong>Install from source</strong> (developers — enables <code>u</code>-key self-updates)</summary>

Requirements: the Swift toolchain (Xcode or the Command Line Tools; the package targets macOS 14+ but only macOS 26 is tested). A free Apple ID signed into Xcode is strongly recommended: Marduk codesigns its builds with the free "Apple Development" certificate so the TCC Accessibility grant is anchored to a stable identity and survives rebuilds — unsigned builds work, but the grant breaks on every update. Then:

```bash
git clone https://github.com/spencer-dollahite/marduk.git
cd marduk
swift build
.build/debug/marduk install     # assembles Marduk.app + installs the launchd
                                # agent (autostart at login, crash restart)
```

Grant Accessibility to the assembled `Marduk.app` at the repo root when the voice asks. Add `.build/debug` to your PATH or symlink the binary so `marduk` resolves.

</details>

### Permissions

Marduk is assistive technology — macOS makes you grant its two deep hooks, and Marduk walks you through both **out loud**:

- **Accessibility** — pick `Marduk.app` in the Settings pane Marduk opens for you. If the grant is ever missing, Marduk says so and heals within ~10 seconds of a fix (if it seems stuck: remove the entry and re-add it — toggling is not enough).
- **Automation** — the first time speech ducks your media, allow the prompts to control System Events / Music / Spotify.

### Privacy

Marduk tracks nothing. No telemetry, no analytics, no accounts, no crash reporting — there is no code that phones home, and I have no interest in knowing how you use your computer. Everything runs locally on your Mac.

The only network activity is checking GitHub for new versions (an unauthenticated request that carries no personal data — `:config checkhours 0` turns even that off) and downloading updates you ask for. The log file at `~/Library/Logs/marduk.log` never leaves your machine; be aware it contains the first ~80 characters of text Marduk has spoken, so redact it before pasting into a bug report (Marduk reminds you of this whenever it copies log lines).

## What it does

- **Vim-style modal keyboard layer** — NORMAL (commands), INSERT (typing), VISUAL / VISUAL LINE (select with `hjkl`, count prefixes like `3j`, read with `r`). A colored-earcon mode system, an escape tap/hold that never steals Escape from vim, and a *typing rescue* that notices when you type into NORMAL mode by mistake, flips to INSERT, and replays your keystrokes so nothing is lost.
- **Reading that respects your audio** — speech pauses your browser/system media (play/pause, only if it was actually playing) and volume-ducks Apple Music/Spotify, then puts everything back when the read ends. Speech and media never fight.
- **Pause and resume** — Space pauses an active read at a word boundary and resumes it; the moment nothing is being read, Space is just Space.
- **A speech preprocessor built for real content** — strips the invisible Unicode that makes TTS silently bail; speaks code symbols by name with configurable verbosity (`->` "arrow", `!=` "not equals"); collapses symbol runs ("5 dash" instead of dash-dash-dash-dash-dash); abbreviates hex digests ("md5 ending in 2 7 e" instead of 32 characters of hex).
- **Two voices** — one for reading content, one for status announcements, so you always know which is which.
- **A vim-style command line with a visual palette** — press `:` in NORMAL mode and a dmenu-style panel opens at your cursor (so it's always inside a zoomed-in view — `:config position center` if you prefer it screen-centered), listing everything you can type with descriptions and current values, filtering as you go: `:help`, `:commands`, `:tutorial`, `:config rate 230`. The moment your typing is unambiguous it just goes — `:h` runs help, `:con` becomes `config` and moves on — no Enter needed except for numbers. Tab completes, arrows browse (spoken), rows are clickable, `?` — or just pausing — speaks your options, and `/` fuzzy-searches everything at once. Settings changed via `:config` apply instantly and persist.
- **A talking interactive tutorial** — `:tutorial` walks you through the modes vimtutor-style: it asks you to actually press the keys and confirms out loud when you get it. First run also greets you with a short spoken orientation.
- **Runs as a proper service** — a launchd agent starts Marduk at login, restarts it if it crashes, and logs to `~/Library/Logs/marduk.log`. Updates are spoken before they're installed: `u` fetches and reads the release notes aloud, `uu` installs (pull, build, codesign, restart), and a daily background check announces when something new is available (`:config autoupdate on` to install automatically, `:config checkhours 0` to disable checks).
- **Signed builds** — binaries are codesigned with your (free) Apple Development certificate so macOS Accessibility permission survives rebuilds.
- **No dependencies** — pure Swift and native Apple frameworks. No Electron, no Python, no network calls.

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

**NORMAL mode** (default): `i` → INSERT · `v` / `V` → VISUAL / VISUAL LINE · `r` selects the paragraph under the cursor (like a triple-click) and reads it · `t` speaks the time (`tt` = time + date) · `s` toggles macOS speak-under-pointer · `u` speaks available updates, `uu` (or `u` again within a minute) installs them · `n` (Firefox Reader only, works from INSERT too when the reader page has focus) hands off to Reader-mode narration — Marduk goes quiet, your media pauses and stays paused until `n` again or `Escape` · `8` (Firefox only) opens Reader mode *and* starts narration in one key; `8` again stops and closes the reader · `Escape` stops speech. Letters you type by mistake trigger the typing rescue (see above); numbers, arrows, and Cmd/Ctrl shortcuts always pass through.

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
- **Reading a selection can overwrite your clipboard** in apps whose accessibility tree won't hand over the selected text (Firefox text boxes, iMessage) or when the selection is huge (Cmd+A on a long document): Marduk falls back to a synthetic Cmd+C and reads the pasteboard, so the clipboard ends up holding the text it just read.
- **Selection reads sound doubled or use the wrong voice?** macOS's own *Speak Selection* feature defaults to the same Option+Escape shortcut, and its hotkey fires alongside Marduk's. Two fixes:
  - *Simple:* turn it off (or rebind it) in System Settings → Accessibility → Read and Speak Content — Marduk owns the key.
  - *Keep macOS as a fallback for when Marduk is down:* Marduk publishes a Karabiner variable `marduk_up` (1 while running and enabled, 0 on stop/disable), and its read command also answers **Ctrl+Option+Escape**. Route your read button conditionally:

    ```json
    { "description": "Read button: Marduk when up, macOS Speak Selection when down",
      "manipulators": [
        { "type": "basic",
          "from": { "key_code": "escape", "modifiers": { "mandatory": ["option"] } },
          "conditions": [ { "type": "variable_if", "name": "marduk_up", "value": 1 } ],
          "to": [ { "key_code": "escape", "modifiers": ["left_control", "left_option"] } ] }
      ] }
    ```

    (Adapt `from` to whatever your read button sends. With `marduk_up` at 0 the rule doesn't fire, the plain Option+Escape goes through, and macOS speaks.) A hard crash can't clear the variable, so the fallback has a gap of a few seconds until launchd relaunches Marduk.
- Hand-edits to config.json need a daemon restart — use `:config` from inside Marduk (or `marduk config rate`) for live changes.
- **Upgrading from a pre-bundle install:** the first update converts Marduk into `Marduk.app` and announces it aloud. If keyboard commands stop afterwards, re-grant Accessibility to `Marduk.app`; the Automation prompt also re-asks once (now explaining why Marduk wants media control).

## Known limitations

- **US (ANSI) keyboard layout is assumed.** Commands are matched by physical key position, so on AZERTY, QWERTZ, or Dvorak layouts the command letters land in the wrong places. A [Karabiner-Elements](https://karabiner-elements.pqrs.org/) remap is a workaround today; proper layout awareness is planned.
- **English only.** Voice pickers list English voices, and everything Marduk says is English.
- **Apple Silicon + macOS 26 (Tahoe) only.** Older macOS versions and Intel Macs are not supported.

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

**Security issues:** please email [spencer@ssdollahite.com](mailto:spencer@ssdollahite.com) instead of opening a public issue — see [SECURITY.md](SECURITY.md). From inside Marduk, `:security` opens a pre-addressed email.

If Marduk is useful to you, you can [sponsor development](https://github.com/sponsors/spencer-dollahite).

## License

[MIT](LICENSE) © Spencer Dollahite
