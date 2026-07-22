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

Releases are signed and notarized — no Xcode, no Terminal, no warnings from macOS. Updates are built in on every install channel: press `u` and Marduk reads the release notes aloud, `u` again installs — the download is verified against the developer signature and notarization before a byte of the running app is touched. `:config autoupdate on` installs silently in the background instead; `brew upgrade` also works for Homebrew installs.

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

The only network activity is checking GitHub for new versions (an unauthenticated request that carries no personal data — `:config checkhours 0` turns even that off) and downloading updates you ask for. The log file at `~/Library/Logs/marduk.log` never leaves your machine — and it never contains the text Marduk reads to you. Logging is allowlisted to metadata (character counts, key codes, error codes, file paths), precisely so a log can be pasted into a public bug report without leaking what you were reading.

## What it does

- **The long-form reader — Marduk's signature.** Press `R` and the document under your mouse becomes an audiobook: Notes, Terminal, PDFs in Preview (page-aware — `Ctrl+F`/`Ctrl+B` turn pages, `12G` jumps to page twelve), and web pages in Safari and Firefox (open the Reader view and it's just the title and article, no clutter). It reads from the pointer to the end, and the view follows the voice — Preview turns its own pages, articles scroll like a teleprompter.
- **Vim navigation inside every read** — the moment anything is being read, the keyboard becomes reading controls, whatever mode you were in: `b`/`w` step by word, `(`/`)` by sentence, `j`/`k` by line, `{`/`}` by paragraph, with counts (`3(`); `gg`/`G` jump to the ends, `f`+char hops to a character, `/` searches, `.` repeats. Jumps are never one-way: `Ctrl+O` walks back to wherever you jumped *from* — through the whole history, however far you went — and `Ctrl+I` walks forward again, exactly like vim's jumplist. `z` spells the current word — again for NATO phonetics ("Mike versus November") — `Z` the sentence. A tap of Escape pauses like Space; holding Escape leaves the read, and `i` drops to INSERT *while the read keeps talking* — type notes as you listen, then hold Escape to hand the keyboard back to the read. Stray keys buzz instead of typing into your app. **These are deliberately vim's keys:** if you know vim, you already know Marduk; if you don't, some choices may seem odd at first — there's a method to the madness, and a few days of muscle memory pays off in navigation speed no menu can match.
- **Vim-style modal keyboard layer** — NORMAL (commands), INSERT (typing), VISUAL / VISUAL LINE (select with `hjkl`, count prefixes like `3j`, read with `r`). A colored-earcon mode system, an escape tap/hold that never steals Escape from vim, and a *typing rescue* that notices when you type into NORMAL mode by mistake, flips to INSERT, and replays your keystrokes so nothing is lost.
- **Reading that respects your audio** — speech pauses your browser/system media (play/pause, only if it was actually playing) and volume-ducks Apple Music/Spotify, then puts everything back when the read ends. Speech and media never fight.
- **Pause and resume** — Space pauses an active read at a word boundary and resumes it; the moment nothing is being read, Space is just Space.
- **Dialog announcements** — password prompts, permission dialogs, and sheets are announced the moment they appear, with their title, even when they open outside your zoomed-in view. No more "why is my Mac unresponsive" while an invisible dialog waits. Tunable: `:config dialogs system` keeps only the central password/permission prompts, `off` silences it.
- **Hover speech** — `s` speaks whatever is under the mouse pointer as it moves, in your reading voice at your rate and pitch, and never interrupts an active read.
- **Your voice, your pronunciations** — Marduk starts in the voice you already chose for macOS Spoken Content, upgraded to its best installed edition; `:voices` auditions every installed voice in its own sound, `:config pitch` tunes it. And the pronunciations you add in System Settings (`:pronunciation` jumps there) apply to Marduk's speech too — typed respellings, voice-captured phonetics, even entries scoped to a single app — something macOS itself never grants third-party speech.
- **Dark-mode survival for bright apps (opt-in)** — `:config invert on` and Marduk flips the system's Invert Colors when a hopelessly bright app comes front, restoring it the moment you leave (Cisco Packet Tracer and Pages are built in; `display.invertForApps` adds your own; requires the Invert Colors shortcut enabled in Keyboard Settings); with your Mac in dark mode, every Preview PDF switches to its dark view automatically (`:config pdfdark` — `auto` by default, `on`/`off` to override); `:config autoinvert on` goes further and *measures* the front window's brightness with a tiny screenshot (Screen Recording permission), inverting only when the content is actually bright — your black-styled slide deck stays exactly as you made it.
- **A mode overlay for residual vision (opt-in)** — `:config border on` frames the screen in the current mode's color (red NORMAL, green INSERT, blue VISUAL, purple while reading); `:config pointer on` puts the same color in a dot that follows the mouse and stays visible while zoomed in.
- **Karabiner-Elements handoff** — with Karabiner installed, your read button reaches Marduk while it runs and falls back to macOS Speak Selection the moment it stops — even after a crash. Marduk manages its own Karabiner profile and always hands yours back (details in Known quirks).
- **A speech preprocessor built for real content** — strips the invisible Unicode that makes TTS silently bail; speaks code symbols by name with configurable verbosity (`->` "arrow", `!=` "not equals"); collapses symbol runs ("5 dash" instead of dash-dash-dash-dash-dash); abbreviates hex digests ("md5 ending in 2 7 e" instead of 32 characters of hex); and reads code identifiers as natural words — `readDocumentFromCaret` and `user_id_count` become "read document from caret" and "user id count" instead of a mumble and a chorus of underscores.
- **Two voices** — one for reading content, one for status announcements, so you always know which is which.
- **A vim-style command line with a visual palette** — press `:` in NORMAL mode and a dmenu-style panel opens at your cursor (so it's always inside a zoomed-in view — `:config position center` if you prefer it screen-centered), listing everything you can type with descriptions and current values, filtering as you go: `:help`, `:commands`, `:tutorial`, `:config rate 230`. The moment your typing is unambiguous it just goes — `:h` runs help, `:con` becomes `config` and moves on — no Enter needed except for numbers. Tab completes, arrows browse (spoken), rows are clickable, `?` — or just pausing — speaks your options, and `/` fuzzy-searches everything at once. Settings changed via `:config` apply instantly and persist.
- **A talking interactive tutorial** — `:tutorial` walks you through the modes vimtutor-style: it asks you to actually press the keys and confirms out loud when you get it. First run also greets you with a short spoken orientation.
- **Runs as a proper service** — a launchd agent starts Marduk at login, restarts it if it crashes, and logs to `~/Library/Logs/marduk.log`. Updates are spoken before they're installed: `u` fetches and reads the release notes aloud, `uu` installs (source builds: pull, build, codesign, restart — release installs: download the signed DMG, verify, swap), and a daily background check announces when something new is available (`:config autoupdate on` to install automatically, `:config checkhours 0` to disable checks).
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

**NORMAL mode** (default): `i` → INSERT · `v` / `V` → VISUAL / VISUAL LINE · `r` selects the paragraph under the cursor (like a triple-click) and reads it · `t` speaks the time (`tt` = time + date) · `R` reads the whole document from the pointer (see Whole-document reading) · `s` toggles hover speech — what's under the pointer, spoken in your reading voice · `u` speaks available updates, `uu` (or `u` again within a minute) installs them · `n` (Firefox Reader only, works from INSERT too when the reader page has focus) hands off to Reader-mode narration — Marduk goes quiet, your media pauses and stays paused until `n` again or `Escape` · `8` (Firefox only) opens Reader mode *and* starts narration in one key; `8` again stops and closes the reader · `Escape` stops speech. Letters you type by mistake trigger the typing rescue (see above); numbers, arrows, and Cmd/Ctrl shortcuts always pass through.

**INSERT mode:** everything passes to the app. *Tap* Escape and the app gets it (vim keeps its Escape); *hold* Escape (~400 ms, configurable) to return to NORMAL.

**VISUAL / VISUAL LINE:** `hjkl` extend the selection (with count prefixes: `v3j`), `G` to end, `r` reads the selection and returns to NORMAL, `Escape` cancels.

**COMMAND mode (`:`):** type `:` in NORMAL for a vim-style command line with a floating palette showing your options. `:help` speaks the basics, `:commands` the full reference, `:tutorial` starts the guided tour, `:tip` speaks a random feature tip, `:quit` / `:restart` control the daemon, `:update` installs updates, `:uninstall` removes the launch agent, `:log` opens the log, `:feedback` / `:bug` open GitHub issues, `:voices` opens the voice picker (each candidate previews in its own voice), `:invertapps` chooses which apps invert the display — the app you were just in comes first, so Return alone adds it; typing filters, and Return on an app already on the list removes it — `:pronunciation` opens the system pronunciation editor, and `:config <setting> <value>` changes settings live — `rate` (50–360 wpm), `pitch` (50–200%), `level` (`none`/`some`/`most`/`all`), `hashes`, `identifiers` (speak `parseHTMLBody` as separate words), `rescue`, `burst`, `escapehold`, `echo` (speak keys as you type, off by default), `commandecho`, `palette`, `position` (`pointer`/`center`), `autoupdate`, `checkhours`, `border`, `pointer`, `thickness`, `speedkeys` (Option+arrows nudge the rate), `togglesound` (`speech`/`earcon`), `readmotions`, `follow` (scroll the view to track the read), `dialogs` (`all`/`system`/`off`), `dialogfocus` (`ask`/`always`/`off` — whether Marduk may jump focus to an announced dialog), `hints` (occasional feature tips), `invert`, `pdfdark` (`auto`/`on`/`off`), `autoinvert`, and `dock`. Everything else takes `on`/`off` or a number. Unique prefixes work everywhere (`:conf ra 230`); Tab completes; `?` or a moment's pause speaks what you can type next; Escape cancels.

### Configuration

`~/.config/marduk/config.json` (auto-created with defaults):

- `speech` — rate, pitch, voice identifier
- `ducking` — duck level, ramp, per-app targets, media-key pause on/off, extra media-key apps
- `keyboard` — escape hold threshold, typing-rescue window and on/off, palette and its position, read motions, dialog alerts, speed keys, toggle sound, Karabiner read button key
- `verbalizer` — symbol verbosity (`none`/`some`/`most`/`all`), per-symbol overrides (`{"*": "asterisk", "%": ""}`), hash abbreviation on/off
- `update` — periodic check interval in hours (0 = off), auto-install on/off
- `overlay` — mode border / pointer dot, per-mode colors, thickness
- `display` — bright-app handling: per-app inversion list, Preview auto dark mode, brightness auto-detection and its threshold

Config is read at daemon start. Most settings can be changed live from inside Marduk with `:config` (which also saves them); if you hand-edit the file instead, restart (or `marduk update`) to apply.

## Known quirks (read before filing bugs)

These are deliberate trade-offs of the typing-rescue system, not bugs:

- **Words starting with "i" lose their leading i** if you type them in NORMAL mode — `i` enters INSERT instantly (so `i`-then-type works), which means typing "is" in NORMAL becomes INSERT + "s". The falling earcon tells you it happened.
- **Single-letter commands fire ~300 ms late** (`r`, `t`, `s`, `u` alone) — that's the typing-rescue window deciding you weren't typing a word. `v`+motion and `i` are instant. Set `keyboard.typingRescue: false` to make all commands instant at the cost of the rescue (and of `tt`).
- **A command followed quickly by `k` reads as typing** — protects words like "skip".
- **Short reads pause your media briefly** even for a two-word utterance — pause/resume is deliberate (volume-ducking a browser can't stop a video, and lowering system volume would quiet Marduk itself). Only recognized media apps and browsers are paused; calls, games, and other audio are spoken over (an exotic player can be added via `ducking.mediaKeyApps` in config.json).
- **Reading a selection can overwrite your clipboard** in apps whose accessibility tree won't hand over the selected text (Firefox text boxes, iMessage) or when the selection is huge (Cmd+A on a long document): Marduk falls back to a synthetic Cmd+C and reads the pasteboard, so the clipboard ends up holding the text it just read.
- **Selection reads sound doubled or use the wrong voice?** macOS's own *Speak Selection* feature defaults to the same Option+Escape shortcut, and its hotkey fires alongside Marduk's. Two fixes:
  - *Simple:* turn it off (or rebind it) in System Settings → Accessibility → Read and Speak Content — Marduk owns the key.
  - *With Karabiner-Elements installed (recommended — Marduk assumes it), this is automatic.* Marduk manages its own Karabiner profile named **"Marduk"**: on every start it adopts that profile if you made one (preserving everything you put in it — only Marduk's own rule is refreshed inside it), or bootstraps it as a clone of your selected profile, then selects it via `karabiner_cli`. On stop, Ctrl+Option+M disable, logout, or even a crash (a minimal signal handler), your own profile comes back — reads fall back to macOS Speak Selection with no manual switching, ever. Only SIGKILL/power loss escapes, and the relaunch heals that in seconds. Notes:
    - Marduk's rule maps the read button (`keyboard.karabinerReadKey` in config.json, default `equal_sign` — a Razer Naga's side button 12) to Marduk's read chord while up, plain Option+Escape otherwise. Check your button's real key_code in Karabiner-EventViewer if it differs.
    - Remove any old rule of yours that maps the same button to Option+Escape — first match wins, and it would shadow Marduk's.
    - `karabiner.json` is backed up to `karabiner.json.marduk-backup` before every rewrite; non-Marduk profiles are never modified or deleted.
    - Without Karabiner, or to wire it by hand: [`assets/karabiner/marduk-read-button.json`](assets/karabiner/marduk-read-button.json) is the standalone rule.
- Hand-edits to config.json need a daemon restart — use `:config` from inside Marduk (or `marduk config rate`) for live changes.
- **Upgrading from a pre-bundle install:** the first update converts Marduk into `Marduk.app` and announces it aloud. If keyboard commands stop afterwards, re-grant Accessibility to `Marduk.app`; the Automation prompt also re-asks once (now explaining why Marduk wants media control).

### Emergency stop

Marduk is a background daemon — by default it has no Dock icon and macOS excludes it from the Force Quit window (`:config dock on` makes it a visible app: Dock, app switcher, and Force Quit, as one package) (and force-killing wouldn't help: the launch agent restarts it in seconds, by design). The stops that work, gentlest first:

1. **`Ctrl+Option+Delete`** (with Karabiner) — the panic chord. Karabiner itself force-kills Marduk, upstream of everything, so it works even if Marduk is wedged and eating keys. The launch agent restarts it fresh in ~10 seconds; repeated panics put it in safe mode.
2. **`Ctrl+Option+M`** — instant off. Keys pass through untouched, your Karabiner profile comes back. Same chord turns it back on.
3. **`:quit`** — stops the daemon cleanly; it stays stopped until next login or `marduk start`.
4. **`marduk stop`** in Terminal — same as `:quit`, from outside.
5. **Activity Monitor → marduk → Force Quit** — works as a last resort, but expect the automatic relaunch; follow with `marduk stop` if you want it to stay down.

## Known limitations

- **US (ANSI) keyboard layout is assumed.** Commands are matched by physical key position, so on AZERTY, QWERTZ, or Dvorak layouts the command letters land in the wrong places. A [Karabiner-Elements](https://karabiner-elements.pqrs.org/) remap is a workaround today; proper layout awareness is planned.
- **English only.** Voice pickers list English voices, and everything Marduk says is English.
- **Apple Silicon + macOS 26 (Tahoe) only.** Older macOS versions and Intel Macs are not supported. On a newer macOS major, Marduk says so once and keeps going; if it ever crash-loops there, it restarts in a safe mode that keeps speech and self-update alive so the fix can reach you.

## How it works

A background daemon (no UI) built on the C-level `AXUIElement` accessibility API, `CGEventTap` for the modal keyboard layer, `AVSpeechSynthesizer` for speech, and CoreAudio + AppleScript for media-aware ducking — the same primitives VoiceOver-class tools use, since Apple ships no third-party screen-reader SDK. Architecture notes live in [CLAUDE.md](CLAUDE.md) and the long-form design in [PLAN.md](PLAN.md).

## Roadmap (rough, no promises)

- Accessibility-tree navigation (element-wise `hjkl`, headings/links quick-nav)
- OCR fallback for scanned PDFs and inaccessible apps (Vision framework)
- Spatial/earcon audio themes
- Non-US keyboard layouts

Explicitly **out of scope**: braille, and full screen-reader parity with VoiceOver/NVDA.

## Contributing

Issues, bug reports, and "this assumption doesn't survive contact with my setup" reports are very welcome — especially from low-vision users. This is a personal project maintained at personal-project pace; PRs are welcome but may sit.

**When filing bugs:** `:bug` opens a prefilled report and `:log copy` puts the recent log on your clipboard — the log contains no text Marduk has read (only key codes and metadata), so it's safe to paste as-is.

**Security issues:** please email [spencer@ssdollahite.com](mailto:spencer@ssdollahite.com) instead of opening a public issue — see [SECURITY.md](SECURITY.md). From inside Marduk, `:security` opens a pre-addressed email.

If Marduk is useful to you, you can [sponsor development](https://github.com/sponsors/spencer-dollahite).

## License

[MIT](LICENSE) © Spencer Dollahite
