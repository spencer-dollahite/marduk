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
- **Runs as a proper service** — a launchd agent starts Marduk at login, restarts it if it crashes, and logs to `~/Library/Logs/marduk.log`. Self-updating via a hotkey or `marduk update` (pull, build, codesign, restart).
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

**Always active:** `Ctrl+Option+M` toggles Marduk on/off · `Option+Escape` speaks the current selection, or stops speech if speaking.

**Space (NORMAL/VISUAL):** pauses/resumes an active read — but only while something is actually being read; otherwise it's a normal Space, and in INSERT mode it is *always* a normal space. `Escape` cancels a paused read, freeing Space immediately.

**NORMAL mode** (default): `i` → INSERT · `v` / `V` → VISUAL / VISUAL LINE · `r` reads the current line · `t` speaks the time (`tt` = time + date) · `s` toggles macOS speak-under-pointer · `u` self-update · `Escape` stops speech. Letters you type by mistake trigger the typing rescue (see above); numbers, arrows, and Cmd/Ctrl shortcuts always pass through.

**INSERT mode:** everything passes to the app. *Tap* Escape and the app gets it (vim keeps its Escape); *hold* Escape (~400 ms, configurable) to return to NORMAL.

**VISUAL / VISUAL LINE:** `hjkl` extend the selection (with count prefixes: `v3j`), `G` to end, `r` reads the selection and returns to NORMAL, `Escape` cancels.

### Configuration

`~/.config/marduk/config.json` (auto-created with defaults):

- `speech` — rate, voice identifier
- `ducking` — duck level, ramp, per-app targets, media-key pause on/off
- `keyboard` — escape hold threshold, typing-rescue window, rescue on/off
- `verbalizer` — symbol verbosity (`none`/`some`/`most`/`all`), per-symbol overrides (`{"*": "asterisk", "%": ""}`), hash abbreviation on/off
- `display` — per-app color inversion list

Config is read at daemon start; restart (or `marduk update`) after editing.

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

If Marduk is useful to you, you can [sponsor development](https://github.com/sponsors/spencer-dollahite).

## License

[MIT](LICENSE) © Spencer Dollahite
