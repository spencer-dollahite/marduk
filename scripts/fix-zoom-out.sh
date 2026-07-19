#!/bin/bash
# fix-zoom-out.sh — Patch the live Karabiner config so Naga button 4 (Zoom Out
# Fully) posts 20 native Option+Command+Hyphen events through Karabiner's
# virtual keyboard. Handles both broken forms:
#   - the original osascript/System Events shell_command (breaks when a macOS
#     or Karabiner update resets TCC permissions)
#   - the first native rewrite, which sent Option+Shift+Hyphen — but the macOS
#     Zoom Out shortcut is Option+Command+minus, so it typed em dashes instead
# Backs up the config first, then restarts karabiner_console_user_server —
# auto-reload on file change has been observed to silently not happen
# (2026-07: patched config was correct on disk but the running instance kept
# posting the old events until a killall).
set -euo pipefail

CONFIG="$HOME/.config/karabiner/karabiner.json"
BACKUP="$CONFIG.bak.$(date +%Y%m%d%H%M%S)"

[ -f "$CONFIG" ] || { echo "No config at $CONFIG"; exit 1; }
cp "$CONFIG" "$BACKUP"
echo "Backup: $BACKUP"

python3 - "$CONFIG" <<'EOF'
import json, sys

path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

native = [
    {"key_code": "hyphen",
     "modifiers": ["left_option", "left_command"],
     "hold_down_milliseconds": 30}
    for _ in range(20)
]

def needs_patch(to):
    if not to:
        return False
    first = to[0]
    if "shell_command" in first and "key code 27" in first["shell_command"]:
        return True  # old osascript form
    if first.get("key_code") == "hyphen" and first.get("modifiers") == ["left_option", "left_shift"]:
        return True  # first native rewrite, wrong modifiers
    return False

n = 0
for profile in data.get("profiles", []):
    for rule in profile.get("complex_modifications", {}).get("rules", []):
        for m in rule.get("manipulators", []):
            if needs_patch(m.get("to", [])):
                m["to"] = list(native)
                n += 1

if n == 0:
    print("No zoom-out rule needing a patch — config already correct or rule missing.")
    sys.exit(0)

with open(path, "w") as f:
    json.dump(data, f, indent=4)
    f.write("\n")
print(f"Patched {n} rule(s).")
EOF

echo "Restarting Karabiner so the running instance picks up the config..."
killall karabiner_console_user_server 2>/dev/null || true
echo "Done (karabiner_console_user_server relaunches itself)."
