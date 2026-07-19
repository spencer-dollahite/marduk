# Marduk -- Assistive Technology Platform for macOS

## Vision

Marduk is a next-generation assistive technology platform for macOS 26 that provides a richer, more customizable alternative to VoiceOver. It combines Apple's native Accessibility APIs, spatial audio soundscapes, AI-powered screen understanding, and Karabiner Elements for modal keyboard control into a unified experience for users with visual impairments.

---

## Architecture Overview

```
+-----------------------------------------------------------------------+
|                           MARDUK CORE                                  |
|                                                                        |
|  +------------------+  +------------------+  +---------------------+   |
|  |  Input Layer     |  |  Screen Model    |  |  Output Layer       |   |
|  |                  |  |                  |  |                     |   |
|  |  Karabiner       |  |  AX Tree Walker  |  |  Speech Engine      |   |
|  |  CGEventTap      |  |  AX Observer     |  |  Spatial Audio      |   |
|  |  Mouse Tracker   |  |  Screen Capture  |  |  Earcon System      |   |
|  |  Hotkey Manager  |  |  Vision OCR      |  |  Audio Ducker       |   |
|  |                  |  |  AI Vision       |  |  Haptic Feedback     |   |
|  +--------+---------+  +--------+---------+  +----------+----------+   |
|           |                      |                       |              |
|           +----------+-----------+-----------+-----------+              |
|                      |                       |                          |
|              +-------v--------+     +--------v---------+               |
|              |  Navigation    |     |  Mode Controller |               |
|              |  Engine        |     |                  |               |
|              |                |     |  Normal Mode     |               |
|              |  Marduk Cursor |     |  Text Mode       |               |
|              |  Rotor         |     |  App Switcher    |               |
|              |  Element Focus |     |  Passthrough     |               |
|              +----------------+     +------------------+               |
+-----------------------------------------------------------------------+
```

---

## 1. Activation and Modal Control

### 1.1 Global Toggle (Karabiner + Native)

**Activation combo**: `Ctrl+Option+M` (configurable)
- Switches Karabiner to the "Marduk" profile via `karabiner_cli --select-profile "Marduk"`
- Launches/activates the Marduk daemon process
- Plays a distinctive activation earcon + spoken "Marduk on"
- Draws a subtle overlay border around the screen (using a borderless NSWindow at `.screenSaver` level)

**Deactivation combo**: `Ctrl+Option+M` again (toggle), or `Escape` x3 rapid (emergency quit)
- Switches Karabiner back to "Default" profile
- Plays deactivation earcon + spoken "Marduk off"
- Removes overlay

**Implementation**:
- Primary: `CGEventTap` at `kCGHIDEventTap` to intercept the toggle combo
- Fallback: Karabiner complex modification that sets `marduk_active` variable + runs shell command to launch/kill the daemon
- Requires: Accessibility permission (`AXIsProcessTrustedWithOptions`)

### 1.2 Karabiner "Marduk" Profile

A dedicated Karabiner profile containing:
- All Marduk-specific key mappings (active only when Marduk is running)
- Variable-based modal layers for sub-modes (normal, text, app-switcher)
- Passthrough rules that let standard typing work unmodified

```json
{
  "name": "Marduk",
  "complex_modifications": {
    "rules": [
      {
        "description": "Marduk mode layers via variables",
        "manipulators": []
      }
    ]
  }
}
```

### 1.3 Mode Architecture (Vim-Style)

Marduk uses a **vim-inspired modal model**. In Normal mode, every key is a command — no modifier keys needed. This is faster and more ergonomic than VoiceOver's `Ctrl+Option+key` pattern.

| Mode | Vim Analog | Purpose | Entry | Exit |
|------|------------|---------|-------|------|
| **Normal** | Normal mode | Spatial exploration, element navigation | Default when Marduk activates | `i`, `:`, etc. |
| **Insert** | Insert mode | Text input into focused field | `i` or `a` | `Escape` |
| **Text/Read** | Visual mode | Text block reading, paragraph selection | `v` on a text element | `Escape` |
| **Command** | Command mode | Execute named commands | `:` | `Enter` or `Escape` |
| **App Switcher** | -- | Fixed-position app switching | `Cmd+1-9` or `:app` | Selection made or `Escape` |
| **AI Describe** | -- | Full screen description via AI | `D` (describe) | Description complete |
| **Passthrough** | -- | Temporarily disable Marduk input capture | `\\` (hold) | Release `\\` |

The **Marduk key** (for activation/deactivation only): default `Caps Lock` (remapped via Karabiner), alternative `Right Option`, or `Ctrl+Option+M`.

Once Marduk is active, **Normal mode requires no modifier keys** — just single keystrokes, exactly like vim.

---

## 2. Screen Model -- Understanding What's On Screen

### 2.1 Accessibility Tree Walker

The foundation of Marduk's screen understanding. Queries the macOS AX API to build a structured model of the UI.

**Technology**: `AXUIElement` C API (HIServices framework)

**Core operations**:
- `AXUIElementCreateSystemWide()` -- entry point for system-wide queries
- `AXUIElementCreateApplication(pid)` -- per-app tree access
- `AXUIElementCopyElementAtPosition(app, x, y, &element)` -- hit-test at mouse position
- Recursive walk via `kAXChildrenAttribute` to build full tree
- Batch attribute fetching via `AXUIElementCopyMultipleAttributeValues()`

**Element model** (unified abstraction, inspired by NVDA's NVDAObject):

```
MardukElement
  .role: String           // "AXButton", "AXWindow", etc.
  .subrole: String?       // "AXCloseButton", etc.
  .title: String?         // Element title
  .value: Any?            // Element value
  .description: String?   // Accessibility description
  .position: CGPoint      // Screen position (Quartz coords, top-left origin)
  .size: CGSize           // Element dimensions
  .children: [MardukElement]
  .parent: MardukElement?
  .app: MardukApp         // Owning application
  .isTextElement: Bool    // Has text content (AXStaticText, AXTextArea, AXTextField)
  .textContent: String?   // Full text if text element
  .region: ScreenRegion   // Which screen region (menuBar, dock, content, toolbar)
```

### 2.2 Accessibility Observer

Real-time monitoring of UI changes via `AXObserver`.

**Key notifications to observe**:
- `kAXFocusedUIElementChangedNotification` -- focus moved
- `kAXFocusedWindowChangedNotification` -- window focus changed
- `kAXApplicationActivatedNotification` -- app switched
- `kAXValueChangedNotification` -- element value changed (text, sliders, etc.)
- `kAXWindowCreatedNotification` / `kAXUIElementDestroyedNotification` -- window lifecycle
- `kAXWindowMovedNotification` / `kAXWindowResizedNotification` -- layout changes
- `kAXMenuOpenedNotification` / `kAXMenuClosedNotification` -- menu state
- `kAXSelectedTextChangedNotification` -- text selection changes

**Architecture**:
- One `AXObserver` per running application (created via `AXObserverCreate(pid, callback, &observer)`)
- Added to CFRunLoop via `AXObserverGetRunLoopSource()`
- Callbacks update the internal screen model and trigger appropriate audio/speech output
- Stale element references (`kAXErrorInvalidUIElement`) handled gracefully with automatic re-walk

### 2.3 Screen Capture + Vision (Supplementary)

For apps with poor/missing accessibility markup (Electron apps, games, custom-drawn UI).

**Screen capture**: `ScreenCaptureKit` (`SCStream` or `SCScreenshotManager`)
- Capture at reduced resolution (1/2 or 1/4 Retina) for performance
- Configurable frame rate: 2-5 FPS for change detection, on-demand for OCR
- Permission: Screen Recording (TCC)

**OCR**: `VNRecognizeTextRequest` (Vision framework)
- `.fast` recognition level for real-time, `.accurate` for on-demand
- Region-of-interest processing for changed areas only
- Results correlated with AX tree position data for hybrid understanding

**AI Vision** (on-demand, `Marduk+D`):
- **Primary (local)**: Small VLM via MLX or llama.cpp (Florence-2, Phi-3-Vision, or Moondream)
  - 0.5-3s latency, fully private, no network
- **Fallback (cloud)**: Claude API with screenshot
  - 2-5s latency, highest quality, requires user consent for privacy
- User configurable: local-only, cloud-allowed, or ask-each-time

### 2.4 Screen Region Model

Marduk divides the screen into semantic regions with distinct audio identities:

```
+------------------------------------------------------------------+
|  MENU BAR (region: menuBar, sound buffer: menuBarChannel)         |
+------------------------------------------------------------------+
|                                                                    |
|  WINDOW CONTENT                                                    |
|  (region: content, sound buffer: contentChannel)                   |
|                                                                    |
|  +-------------------------------+  +---------------------------+  |
|  |  WINDOW A                     |  |  WINDOW B                 |  |
|  |  (subregion per window)       |  |  (subregion per window)   |  |
|  +-------------------------------+  +---------------------------+  |
|                                                                    |
+------------------------------------------------------------------+
|  DOCK (region: dock, sound buffer: dockChannel)                    |
+------------------------------------------------------------------+
```

**Edge barriers**:
- Top edge: Distinct "ceiling" earcon when mouse reaches y=0 (menu bar boundary)
- Bottom edge: "Floor" earcon at dock boundary
- Left/Right edges: "Wall" earcons at screen bounds
- Between windows: Transitional tone shift when crossing window boundaries

---

## 3. Audio Engine -- The Soundscape

### 3.1 Architecture

Single `AVAudioEngine` instance with multiple submixers:

```
AVAudioEngine
  |
  +-- speechPlayerNode --> speechMixer (volume: independent) --+
  |                                                             |
  +-- earconPlayerNode1 --> AVAudioEnvironmentNode (spatial) --+-- mainMixer --> output
  |   earconPlayerNode2 -->   (HRTF rendering)                |
  |   earconPlayerNode3 -->                                    |
  |                                                             |
  +-- ambientPlayerNode --> ambientMixer (volume: low) --------+
```

**Key design decisions**:
- `AVAudioEnvironmentNode` with `.HRTF` rendering for headphone users (spatial earcons)
- `AVAudioPlayerNode` per concurrent sound source (pre-allocated pool of ~8 nodes)
- All earcons pre-loaded as `AVAudioPCMBuffer` at startup for <10ms playback latency
- Engine runs continuously while Marduk is active (no start/stop latency)
- CoreAudio HAL buffer size set to 256 frames (~5.8ms at 44.1kHz)

### 3.2 Spatial Audio Mapping

Mouse/cursor screen position maps to 3D audio coordinates:

| Screen Axis | Audio Axis | Mapping |
|-------------|------------|---------|
| X (horizontal) | AVAudio3DPoint.x | Left edge = -1.0, Right edge = +1.0 |
| Y (vertical) | AVAudio3DPoint.y | Top = +0.5, Bottom = -0.5 |
| Depth (hierarchy) | AVAudio3DPoint.z | Top-level = 0.0, Nested deeper = -0.3 per level |

The listener position stays at origin (0, 0, 0). Sound sources move based on the element's screen position.

### 3.3 Earcon Design

| Event | Earcon Type | Duration | Notes |
|-------|-------------|----------|-------|
| Enter window | Rising two-tone chime | 150ms | Pitch based on window's vertical position |
| Leave window | Falling two-tone | 150ms | Inverse of enter |
| Cross window boundary | Crossfade transition | 200ms | Old window fades, new fades in |
| Hit screen edge (top) | High metallic ping | 100ms | Positioned at top of stereo field |
| Hit screen edge (bottom) | Low thud | 100ms | Positioned at bottom |
| Hit screen edge (left/right) | Soft knock | 100ms | Hard-panned to respective side |
| Enter menu bar | Distinctive menu tone | 120ms | Separate sound buffer |
| Enter dock | Dock-specific tone | 120ms | Separate sound buffer |
| Focus on button | Soft click | 50ms | |
| Focus on text field | Typewriter tick | 50ms | |
| Focus on link | Glass chime | 60ms | |
| Focus on heading | Bell tone, pitch = heading level | 80ms | H1 = low, H6 = high |
| Focus on image | Camera shutter | 80ms | |
| Empty area | Hollow wind | 200ms | Low volume |
| Error/boundary | Bonk | 100ms | Classic screen reader boundary |
| Mode change | Mode-specific jingle | 200ms | Unique per mode |

### 3.4 Audio Ducking (External Apps)

When Marduk speaks, background music from other apps is automatically ducked:

**Flow**:
1. `AVSpeechSynthesizerDelegate.speechSynthesizer(_:didStart:)` fires
2. Marduk identifies active audio sources via `NSWorkspace.runningApplications` + heuristic (apps known to play audio: Music, Spotify, browsers, etc.)
3. Sends AppleScript volume commands with smooth ramp:
   ```
   tell application "Music" to set sound volume to 25  -- duck to 25%
   ```
4. Ramp is stepped over ~300ms (100 -> 75 -> 50 -> 25) via dispatch timer
5. `AVSpeechSynthesizerDelegate.speechSynthesizer(_:didFinish:)` triggers ramp back up
6. 300ms ramp back to original volume

**Configurable**:
- Duck level: 0-100% (default 25%)
- Ramp duration: 100-500ms (default 300ms)
- Which apps to duck (auto-detect or user-specified list)
- Option to pause instead of duck (legacy behavior)

### 3.5 Haptic Feedback (Trackpad)

`NSHapticFeedbackManager` complements audio for trackpad users:
- `.alignment` tick when crossing UI element boundaries
- `.levelChange` click when entering/leaving major regions (windows, menu bar, dock)
- Configurable: on/off, only when trackpad is being used

---

## 4. Normal Mode -- Spatial Exploration

### 4.1 Mouse Tracking

When the user moves the mouse, Marduk continuously:

1. **Tracks mouse position** via `CGEventTap` (passive, `kCGEventTapOptionListenOnly`) for `kCGEventMouseMoved`
2. **Hit-tests the AX tree** at the mouse position via `AXUIElementCopyElementAtPosition()`
3. **Determines the current region** (menu bar, dock, content window, screen edge)
4. **Updates the spatial audio** -- earcon sources positioned at the element's screen location
5. **Announces element** -- speaks role + title when dwelling on a new element (configurable dwell time: 100-500ms)

### 4.2 Window Awareness

When the mouse crosses from one window to another:
- **Transition sound**: Crossfade earcon with spatial positioning
- **Window announcement**: Speaks "[App name] - [Window title]"
- **Visual hint** (optional): Subtle highlight border on current window via overlay

**Implementation**:
- Track current window via `kAXWindowAttribute` of the element under cursor
- Compare with previous window on each mouse move event
- Window boundary detection using `kAXPositionAttribute` + `kAXSizeAttribute`

### 4.3 Vim-Style Keybinding System

When Marduk is active and in **Normal mode**, every key is a command. No modifier keys required.

#### Movement (h/j/k/l)

| Key | Action | Notes |
|-----|--------|-------|
| `h` | Move to previous sibling element | Left in the UI tree |
| `l` | Move to next sibling element | Right in the UI tree |
| `j` | Move to next element (depth-first) | Down through the page |
| `k` | Move to previous element (depth-first) | Up through the page |
| `H` (shift) | Move to previous window | Cycle windows backward |
| `L` (shift) | Move to next window | Cycle windows forward |
| `J` (shift) | Enter container (first child) | Drill into a group |
| `K` (shift) | Exit container (parent) | Back up to parent |

#### Jumps and Marks

| Key | Action | Notes |
|-----|--------|-------|
| `gg` | Jump to menu bar | Top of screen, like `gg` = top of file |
| `G` | Jump to dock | Bottom of screen, like `G` = end of file |
| `gw` | Jump to main window content | Center content area |
| `gt` | Jump to toolbar | Current window's toolbar |
| `gn` | Jump to notification center | Right side panel |
| `0` | First element in current container | Like `0` = start of line |
| `$` | Last element in current container | Like `$` = end of line |
| `m{a-z}` | Set mark at current element | Remember this position |
| `'{a-z}` | Jump to mark | Return to marked position |
| `''` | Jump to previous position | Like vim `''` |
| `Ctrl+O` | Jump back in history | Navigate position stack |
| `Ctrl+I` | Jump forward in history | Navigate position stack |

#### Search and Quick Navigation

| Key | Action | Notes |
|-----|--------|-------|
| `/` | Search for element by text | Fuzzy search across all visible elements |
| `n` | Next search match | |
| `N` | Previous search match | |
| `f{char}` | Jump to next element starting with {char} | Like vim's `f` motion |
| `;` | Repeat last `f` jump | |

#### Element-Type Quick Nav (like vim motions)

| Key | Action | Notes |
|-----|--------|-------|
| `[h` | Previous heading | `]h` for next heading |
| `]h` | Next heading | |
| `[b` | Previous button | `]b` for next button |
| `]b` | Next button | |
| `[l` | Previous link | `]l` for next link |
| `]l` | Next link | |
| `[f` | Previous form control | `]f` for next form |
| `]f` | Next form control | |
| `[i` | Previous image | `]i` for next image |
| `]i` | Next image | |
| `[t` | Previous table | `]t` for next table |
| `]t` | Next table | |
| `1-6` | Jump to next heading at level 1-6 | Like vim line numbers |

#### Actions

| Key | Action | Notes |
|-----|--------|-------|
| `Enter` or `Space` | Activate/press current element | Click button, follow link |
| `o` | Open/expand current element | Disclosure triangle, tree node |
| `O` | Close/collapse current element | |
| `y` | Yank (copy) current element text | To clipboard |
| `yy` | Yank full line/element description | Role + title + value |
| `p` | Paste from clipboard | Into focused text field |
| `.` | Repeat last action | |

#### Mode Switching

| Key | Action | Notes |
|-----|--------|-------|
| `i` | Enter **Insert mode** | Finds nearest text input and focuses it |
| `a` | Enter Insert mode (append) | Focuses text input, cursor at end |
| `I` | Enter Insert mode at first input in container | |
| `v` | Enter **Text/Read mode** | On a text element, enables reading controls |
| `V` | Enter Text/Read mode, select full block | Read entire text block |
| `:` | Enter **Command mode** | Command prompt at bottom |
| `D` | **AI Describe** current element or screen | On image: describe image. Elsewhere: describe screen |
| `\\` | Hold for **Passthrough** | Keys pass through to app while held |
| `Escape` x3 | **Quit Marduk** | Emergency exit, triple-tap safety |

#### Rotor (Dimension Selector)

| Key | Action | Notes |
|-----|--------|-------|
| `r` | Open rotor | Presents navigation categories |
| Then `h/l` | Cycle categories | Headings, Links, Buttons, Forms, Landmarks, Images, Windows |
| Then `j/k` | Navigate within category | Next/prev of that type |
| `Escape` | Dismiss rotor | |

The rotor reads `NSAccessibilityCustomRotor` data from apps that define custom rotors.

### 4.4 Insert Mode

Entered with `i` or `a`. Marduk finds the nearest text input field:

1. From the current element, walk up/across the AX tree looking for `AXTextField` or `AXTextArea`
2. Focus it via `AXUIElementSetAttributeValue(element, kAXFocusedAttribute, kCFBooleanTrue)`
3. Announce: "Insert mode - [field label]"
4. **All keystrokes pass through** to the focused text field (Marduk stops intercepting)
5. `Escape` exits insert mode, returns to Normal mode with announcement: "Normal mode"

Behavior in Insert mode:
- Typing goes directly to the focused field
- `Escape` = exit to Normal mode
- `Ctrl+[` = exit to Normal mode (vim alternative)
- Marduk continues to provide audio feedback (earcons on typing, error sounds on invalid input)
- If focus leaves the text field (e.g., Tab to next field), Marduk announces the new field and stays in Insert mode

### 4.5 Command Mode

Entered with `:`. A command prompt appears (spoken: "Command:"):

| Command | Action |
|---------|--------|
| `:q` | Quit Marduk |
| `:set voice {name}` | Change TTS voice |
| `:set rate {1-100}` | Set speech rate |
| `:set duck {0-100}` | Set ducking level |
| `:set theme {name}` | Switch earcon theme |
| `:app {slot} {name}` | Assign app to slot (e.g., `:app 1 Safari`) |
| `:apps` | List all app slot assignments |
| `:desc` | AI describe full screen |
| `:ocr` | Run OCR on screen, read all text |
| `:help` | Read available commands |
| `:help {key}` | Describe what a key does |
| `:marks` | List all marks |
| `:map {key} {action}` | Custom key mapping |
| `:w` | Save current configuration |
| `:mute` | Toggle all audio |
| `:vol {0-100}` | Set Marduk master volume |
| `:find {text}` | Search for text on screen (same as `/`) |
| `:{number}` | Jump to element #{number} in current list |

`Enter` executes, `Escape` cancels. Tab completion for command names.

### 4.6 Text/Read Mode (Visual Mode)

Entered with `v` when on a text element. Navigation changes to text granularity:

| Key | Action |
|-----|--------|
| `h/l` | Move by character |
| `w/b` | Move by word (forward/backward) |
| `j/k` | Move by line |
| `{/}` | Move by paragraph |
| `(/)` | Move by sentence |
| `gg` | Go to start of text |
| `G` | Go to end of text |
| `Space` | Pause/resume reading |
| `Enter` | Read from current position (Say All) |
| `y` | Copy current selection/paragraph |
| `V` | Select entire text block and read |
| `Escape` | Exit to Normal mode |
| `+` / `-` | Increase/decrease speech rate |

---

## 5. Text Mode

### 5.1 Detection

Text mode activates when:
- The Marduk cursor (mouse or keyboard-navigated) lands on an element with role `AXStaticText`, `AXTextArea`, or `AXTextField`
- Or the user explicitly enters text mode with `Marduk+T`

Detection uses `kAXRoleAttribute` check. For `AXStaticText` and `AXTextArea`, text content is retrieved via `kAXValueAttribute`.

### 5.2 Text Navigation and Reading

Uses vim-style bindings from Text/Read mode (see 4.6):

| Key | Action | Vim Analog |
|-----|--------|------------|
| `Enter` | Read all text from current position (Say All) | -- |
| `h` / `l` | Read by character | Character motion |
| `w` / `b` | Read by word | Word motion |
| `j` / `k` | Read by line | Line motion |
| `{` / `}` | Read by paragraph | Paragraph motion |
| `(` / `)` | Read by sentence | Sentence motion |
| `gg` / `G` | Go to start/end of text | File start/end |
| `Space` | Pause/resume reading | -- |
| `y` | Copy current paragraph to clipboard | Yank |
| `V` | Select and read entire text block | Visual line |
| `+` / `-` | Speech rate up/down | -- |
| `Escape` | Stop reading, exit to Normal mode | -- |

**Implementation**:
- For `AXTextArea`/`AXTextField`: Use parameterized attributes
  - `kAXStringForRangeParameterizedAttribute` to get text for a range
  - `kAXRangeForLineParameterizedAttribute` to get line boundaries
  - `kAXLineForIndexParameterizedAttribute` to map position to lines
  - `kAXNumberOfCharactersAttribute` for total length
- For `AXStaticText`: Get full text from `kAXValueAttribute`, parse paragraphs/sentences in Marduk
- Speech via `AVSpeechSynthesizer` with `AVSpeechUtterance`:
  - Word boundary callback (`willSpeakRangeOfSpeechString:utterance:`) for synchronized highlighting
  - Rate/pitch/volume per utterance
  - SSML support for rich pronunciation (macOS 13+)

### 5.3 Text Selection and Speak Selection

In Text/Read mode (`v`), vim-style selection:

| Key | Action |
|-----|--------|
| `V` | Select and read entire text block |
| `vip` | Select inner paragraph (vim text object) |
| `vis` | Select inner sentence |
| `y` | Copy selected text to clipboard |
| `Enter` | Speak selection |

Audio ducking engages automatically when reading begins, and disengages when complete.

---

## 6. App Switcher -- Pinned Application Slots

### 6.1 Design

Fixed-position app switching where `Cmd+1` through `Cmd+9` always open the same application, regardless of Cmd+Tab order.

**User-configured slot mapping** stored in `~/.config/marduk/apps.json`:

```json
{
  "slots": {
    "1": { "bundleId": "com.apple.Safari", "name": "Safari" },
    "2": { "bundleId": "com.microsoft.VSCode", "name": "VS Code" },
    "3": { "bundleId": "com.apple.Terminal", "name": "Terminal" },
    "4": { "bundleId": "com.tinyspeck.slackmacgap", "name": "Slack" },
    "5": { "bundleId": "com.apple.MobileSMS", "name": "Messages" }
  }
}
```

### 6.2 Implementation Options

**Option A: Karabiner (primary, recommended)**
- Karabiner "Marduk" profile intercepts `Cmd+1` through `Cmd+9`
- Maps to `shell_command: "open -b com.apple.Safari"` (using bundle ID for reliability)
- Pro: Works at the HID level, extremely reliable, no latency
- Con: Conflicts with apps that use `Cmd+1-9` (browsers for tabs, etc.)
- Mitigation: `frontmost_application_unless` conditions to exclude browsers, or use `Hyper+1-9` instead

**Option B: Marduk daemon (fallback)**
- `CGEventTap` intercepts `Cmd+1-9` when Marduk is active
- Marduk activates the target app via `NSWorkspace.shared.open(URL(string: "bundleId://...")!)` or `NSRunningApplication.activate()`
- Pro: More flexible, can add audio confirmation
- Con: Slightly higher latency than Karabiner

**Option C: Hybrid**
- Karabiner sends a unique key (e.g., `F13`+modifier) which Marduk's daemon intercepts and handles
- This lets Marduk add audio feedback while keeping Karabiner's low-level reliability

### 6.3 Audio Feedback

When switching apps via pinned slots:
- Speak: "[Slot number]. [App name]"
- Earcon: App-switch whoosh sound
- If app is not running: "Launching [App name]" + launch sound

### 6.4 Conflict Resolution

Apps that use `Cmd+1-9` for their own purposes (browsers, Finder):
- **Strategy 1**: Use `Hyper+1-9` (where Hyper = `Cmd+Ctrl+Option+Shift`, mapped from Caps Lock via Karabiner)
- **Strategy 2**: Karabiner `frontmost_application_unless` excludes browsers; inside browsers, `Cmd+1-9` works normally for tabs
- **Strategy 3**: Marduk+number (using the Marduk modifier key) for pinned apps, leaving `Cmd+1-9` untouched
- User configurable in settings

---

## 7. AI-Powered Screen Description

### 7.1 Triggered Description (`Marduk+D`)

On demand, captures the screen and provides a natural-language description:

**Pipeline**:
1. Capture screen via `SCScreenshotManager.captureImage()` (single frame)
2. Run `VNRecognizeTextRequest` (.accurate) for OCR
3. Walk AX tree for structural context
4. Combine into a prompt for the vision model:
   - "Describe what is visible on this macOS screen. The accessibility tree shows: [AX summary]. OCR text found: [OCR results]. Describe the layout, key UI elements, and any images or visual content."
5. Send to local VLM or cloud API based on user preference
6. Speak the description via `AVSpeechSynthesizer`
7. Audio ducking active during description

### 7.2 Contextual Micro-Descriptions

Lighter-weight AI descriptions for specific elements:
- `Marduk+I` on an image: Describe just the image under the cursor
- Uses Vision framework `VNClassifyImageRequest` + local VLM for quick description
- Target latency: <2s for local, <5s for cloud

### 7.3 Privacy Model

- **Local-only mode**: All processing on-device via MLX/llama.cpp. No data leaves the Mac.
- **Cloud-assisted mode**: User explicitly opts in. Screenshots sent to Claude API with encryption in transit.
- **Hybrid mode**: Local first, cloud fallback if local model confidence is low.
- Clear indicator (earcon) when cloud is being used.
- No persistent storage of screenshots on any server.

---

## 8. Technology Stack Summary

### Frameworks (Native, First-Class)

| Component | Framework | Key Classes/Functions |
|-----------|-----------|----------------------|
| UI Tree Access | ApplicationServices/HIServices | `AXUIElement*`, `AXObserver*`, `AXValue*` |
| UI Change Monitoring | ApplicationServices/HIServices | `AXObserverCreate`, `AXObserverAddNotification` |
| Event Interception | CoreGraphics | `CGEventTapCreate`, `CGEventPost` |
| Permission Check | ApplicationServices | `AXIsProcessTrustedWithOptions` |
| Text-to-Speech | AVFoundation/AVFAudio | `AVSpeechSynthesizer`, `AVSpeechUtterance` |
| Audio Engine | AVFoundation/AVFAudio | `AVAudioEngine`, `AVAudioPlayerNode`, `AVAudioEnvironmentNode` |
| Spatial Audio | AVFoundation/AVFAudio | `AVAudioEnvironmentNode` with HRTF, `AVAudio3DPoint` |
| Screen Capture | ScreenCaptureKit | `SCStream`, `SCScreenshotManager`, `SCContentFilter` |
| OCR | Vision | `VNRecognizeTextRequest` |
| Image Analysis | Vision + CoreML | `VNClassifyImageRequest`, `VNCoreMLRequest` |
| Haptic Feedback | AppKit | `NSHapticFeedbackManager` |
| App Management | AppKit | `NSWorkspace`, `NSRunningApplication` |
| Local AI | MLX / llama.cpp | Florence-2, Phi-3-Vision, Moondream |
| Cloud AI | Anthropic SDK | Claude API (vision) |

### External Tools (Fallback/Complement)

| Tool | Role |
|------|------|
| **Karabiner Elements** | Modal key layers, Marduk profile, `Cmd+N` app slots, Hyper key |
| **Hammerspoon** (optional) | Complex window management, bridge between Karabiner and Marduk |

### Language and Build

- **Language**: Swift (primary), with C interop for AX API calls
- **Build**: Xcode project, native macOS app (not sandboxed, needs Accessibility + Screen Recording permissions)
- **Minimum macOS**: 15.0 (Sequoia) for modern ScreenCaptureKit + Vision; target 26 for latest APIs
- **Architecture**: Apple Silicon (arm64) primary; Intel support optional

---

## 9. Permissions Required

| Permission | Location | Purpose |
|------------|----------|---------|
| **Accessibility** | Privacy & Security > Accessibility | AX API access, CGEventTap |
| **Screen Recording** | Privacy & Security > Screen Recording | ScreenCaptureKit for AI vision |
| **Input Monitoring** | Privacy & Security > Input Monitoring | Karabiner Elements |
| **Automation** | Privacy & Security > Automation | AppleScript for audio ducking |

First-launch wizard guides user through granting each permission with clear explanations.

---

## 10. Project Structure

```
marduk/
  Marduk.xcodeproj
  Sources/
    App/
      MardukApp.swift              -- App entry point, lifecycle
      MardukDaemon.swift           -- Background daemon management
      Permissions.swift            -- Permission checking and onboarding
    Core/
      ScreenModel.swift            -- Unified screen model
      MardukElement.swift          -- Element abstraction over AX API
      ScreenRegion.swift           -- Region detection (menuBar, dock, content)
      NavigationEngine.swift       -- Cursor, rotor, element focus
      ModeController.swift         -- Mode state machine
    Accessibility/
      AXTreeWalker.swift           -- AX API tree traversal
      AXObserverManager.swift      -- Notification observation
      AXBridge.swift               -- Swift wrappers for C AX API
      ElementHitTest.swift         -- Position-based element lookup
    Audio/
      AudioEngine.swift            -- AVAudioEngine setup and management
      SpeechEngine.swift           -- AVSpeechSynthesizer wrapper
      EarconPlayer.swift           -- Pre-loaded earcon playback
      SpatialAudioMapper.swift     -- Screen position -> 3D audio position
      AudioDucker.swift            -- External app volume control
      HapticManager.swift          -- NSHapticFeedbackManager wrapper
    Input/
      EventTapManager.swift        -- CGEventTap setup and dispatch
      MouseTracker.swift           -- Mouse position monitoring
      HotkeyManager.swift          -- Global hotkey registration
      KarabinerBridge.swift        -- karabiner_cli integration
    Vision/
      ScreenCapture.swift          -- ScreenCaptureKit wrapper
      OCREngine.swift              -- VNRecognizeTextRequest pipeline
      AIDescriber.swift            -- Local VLM + cloud API integration
      ChangeDetector.swift         -- Frame differencing for efficiency
    Modes/
      NormalMode.swift             -- Spatial exploration mode
      TextMode.swift               -- Text reading mode
      AppSwitcherMode.swift        -- Pinned app switching
      PassthroughMode.swift        -- Input passthrough
    Config/
      Settings.swift               -- User preferences
      AppSlots.swift               -- Pinned app configuration
      EarconTheme.swift            -- Audio theme configuration
  Resources/
    Earcons/                       -- Pre-built earcon sound files (.caf)
    Voices/                        -- Custom voice configurations
  Config/
    karabiner/
      marduk-profile.json          -- Karabiner profile definition
      marduk-rules.json            -- Complex modifications
  Tests/
    ...
```

---

## 11. Implementation Phases

Build order: Text/ducking first (solve the immediate pain point), then expand.

### Phase 1: Audio Ducking System
- [ ] Swift package / Xcode project setup
- [ ] `AVAudioEngine` with speech submixer
- [ ] `AVSpeechSynthesizer` with buffer output into audio engine
- [ ] Audio ducking controller:
  - [ ] Firefox volume ducking via system volume (CoreAudio HAL)
  - [ ] Apple Music ducking via AppleScript
  - [ ] Spotify ducking via AppleScript
  - [ ] System-wide fallback via master volume
  - [ ] Smooth ramp (300ms, configurable duck level)
- [ ] `AVSpeechSynthesizerDelegate` hooks: duck on `didStart`, restore on `didFinish`
- [ ] Basic CLI trigger: pipe text to Marduk, it speaks with ducking

### Phase 2: Text Detection + Speech
- [ ] AX API Swift bridge (`AXUIElement` wrappers)
- [ ] Permission check (`AXIsProcessTrustedWithOptions`)
- [ ] Text element detection: identify `AXStaticText`, `AXTextArea`, `AXTextField` under cursor
- [ ] Text extraction via `kAXValueAttribute` and parameterized attributes
- [ ] Firefox Reader Mode auto-trigger:
  - [ ] Detect Reader Mode icon in Firefox AX tree
  - [ ] Send `Cmd+Alt+R` via `CGEventPost` to toggle Reader Mode
  - [ ] Wait for mode switch, then extract clean text
- [ ] First-class app support: iMessage, Notes, Terminal text extraction
- [ ] Multi-granularity reading: character, word, line, paragraph, all
- [ ] Speech rate control (~180 WPM default, +/- adjustment)
- [ ] Minimal verbosity: speak element name only

### Phase 3: Global Toggle + Daemon
- [ ] Background daemon architecture (launchd-compatible)
- [ ] `CGEventTap` for global hotkey interception
- [ ] `Ctrl+Option+M` toggle: activate/deactivate Marduk
- [ ] `Escape` x3 emergency quit
- [ ] Mode state machine (Normal, Insert, Text/Read, Command, Passthrough)
- [ ] Karabiner bridge: `karabiner_cli --set-variables` for mode indicators
- [ ] Config file system (`~/.config/marduk/config.json`)

### Phase 4: Vim Navigation
- [ ] Mouse position tracking via `CGEventTap` (passive)
- [ ] `AXUIElementCopyElementAtPosition()` hit-testing
- [ ] AX tree walker for keyboard navigation
- [ ] Normal mode keybindings: `h/j/k/l`, `gg`, `G`, `gw`, `gt`
- [ ] Element-type quick nav: `]h`, `]b`, `]l`, `]f` (heading, button, link, form)
- [ ] Search: `/` to fuzzy-find elements by text, `n`/`N` for next/prev
- [ ] Marks: `m{a-z}` to set, `'{a-z}` to jump
- [ ] Insert mode: `i` to find and focus nearest text input, `Escape` to exit
- [ ] Command mode: `:` prefix, basic commands (`:q`, `:set rate`, `:help`)
- [ ] Actions: `Enter`/`Space` to activate, `o`/`O` to open/close
- [ ] Position history: `Ctrl+O` / `Ctrl+I` jump stack

### Phase 5: Soundscape + Earcons
- [ ] Spatial audio via `AVAudioEnvironmentNode` (HRTF for AirPods)
- [ ] Screen position -> 3D audio coordinate mapping
- [ ] Earcon theme system (loadable `.caf` sound sets)
- [ ] Region detection: menu bar, dock, content, screen edges
- [ ] Edge barrier sounds (top/bottom/left/right)
- [ ] Window transition sounds (cross-window boundary detection)
- [ ] Element-type earcons (button, link, heading, text, image)
- [ ] AX Observer for real-time UI change notifications
- [ ] App switch detection and announcement
- [ ] Haptic feedback via `NSHapticFeedbackManager` (optional)
- [ ] Enable spatial audio only while Marduk is active

### Phase 6: AI Vision (Deferred)
- [ ] ScreenCaptureKit integration
- [ ] Vision framework OCR pipeline
- [ ] Local VLM (Moondream 1.6B via MLX -- 16GB constraint)
- [ ] `D` key for screen/element description
- [ ] Privacy controls

---

## 12. Key Design Principles

1. **Native first**: Use Apple's first-class APIs wherever possible. Karabiner is a complement, not a crutch.
2. **Spatial awareness**: Audio should encode position. The user should build a mental map of the screen through sound.
3. **Minimal latency**: Earcons <10ms, speech onset <100ms, AI descriptions <3s local / <5s cloud.
4. **Graceful degradation**: If AX tree is missing, fall back to OCR. If OCR fails, fall back to AI vision. Always have something to say.
5. **User control**: Everything is configurable. Modes, keys, sounds, verbosity, AI privacy level.
6. **Non-destructive**: Marduk never modifies the user's system state except through its own overlay. Clean on/off.
7. **Security**: No data leaves the device without explicit consent. Local AI by default. Permissions requested transparently.
