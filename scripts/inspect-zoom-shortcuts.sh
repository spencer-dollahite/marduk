#!/bin/bash
# inspect-zoom-shortcuts.sh — Decode the macOS zoom keyboard shortcuts and
# compare them against what the Karabiner Naga rules post. Read-only diagnostic.
#
# Karabiner sends:  button 1 -> Option+Shift+=      (Zoom In)
#                   button 4 -> Option+Command+- x20 (Zoom Out Fully)
# If a system zoom hotkey is disabled or bound to something else, the combo
# falls through and types literal characters (Option+Shift+- is an em dash).
set -euo pipefail

python3 <<'EOF'
import plistlib, subprocess

MODS = [(0x100000, "Cmd"), (0x080000, "Option"), (0x040000, "Ctrl"), (0x020000, "Shift")]
KEYCODES = {24: "=", 27: "-", 28: "8", 42: "\\"}
ZOOM_IDS = {
    15: "Turn zoom on or off",
    17: "Zoom in",
    19: "Zoom out",
    23: "Image smoothing on/off",
}
EXPECTED = {17: ("Option+Shift", "="), 19: ("Cmd+Option", "-")}

raw = subprocess.check_output(["defaults", "export", "com.apple.symbolichotkeys", "-"])
hotkeys = plistlib.loads(raw).get("AppleSymbolicHotKeys", {})

problems = []
for hid, label in sorted(ZOOM_IDS.items()):
    entry = hotkeys.get(str(hid))
    if entry is None:
        # Absent means macOS factory default: enabled=false for zoom hotkeys
        print(f"[{hid}] {label}: not set (macOS default = DISABLED)")
        if hid in EXPECTED:
            problems.append(f"{label} hotkey missing/disabled")
        continue
    enabled = entry.get("enabled", False)
    params = entry.get("value", {}).get("parameters", [0, 0, 0])
    keycode, modmask = params[1], params[2]
    mods = "+".join(name for bit, name in MODS if modmask & bit) or "(none)"
    key = KEYCODES.get(keycode, f"keycode {keycode}")
    state = "ENABLED" if enabled else "DISABLED"
    print(f"[{hid}] {label}: {state}  {mods}+{key}")
    if hid in EXPECTED:
        want_mods, want_key = EXPECTED[hid]
        if not enabled:
            problems.append(f"{label} is disabled")
        elif (mods, key) != (want_mods, want_key):
            problems.append(f"{label} is bound to {mods}+{key}, Karabiner sends {want_mods}+{want_key}")

print()
if problems:
    print("MISMATCH — this is why button 4 types symbols:")
    for p in problems:
        print(f"  - {p}")
    print("Fix in System Settings > Keyboard > Keyboard Shortcuts > Accessibility > Zoom,")
    print("or System Settings > Accessibility > Zoom > 'Use keyboard shortcuts to zoom'.")
else:
    print("Shortcuts match what Karabiner sends. If button 4 still misbehaves,")
    print("check the Accessibility > Zoom master switch below.")
EOF

echo
echo "Accessibility > Zoom master switch (1 = keyboard shortcuts enabled):"
defaults read com.apple.universalaccess closeViewHotkeysEnabled 2>/dev/null || echo "  (unreadable or unset — check System Settings > Accessibility > Zoom)"
