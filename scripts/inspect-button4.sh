#!/bin/bash
# inspect-button4.sh — Print every Karabiner rule that fires on key "4" or
# mentions zoom, per profile, from the live config. Read-only diagnostic.
set -euo pipefail

CONFIG="$HOME/.config/karabiner/karabiner.json"
[ -f "$CONFIG" ] || { echo "No config at $CONFIG"; exit 1; }

python3 - "$CONFIG" <<'EOF'
import json, sys

d = json.load(open(sys.argv[1]))
for p in d.get("profiles", []):
    sel = " (SELECTED)" if p.get("selected") else ""
    print(f"Profile: {p.get('name')}{sel}")
    for r in p.get("complex_modifications", {}).get("rules", []):
        desc = r.get("description", "")
        for m in r.get("manipulators", []):
            frm = m.get("from", {})
            if frm.get("key_code") == "4" or "zoom" in desc.lower():
                print(f"  rule: {desc}")
                print(f"    from: {json.dumps(frm)}")
                print(f"    to:   {json.dumps(m.get('to'))[:400]}")
    for dev in p.get("devices", []):
        for sm in dev.get("simple_modifications", []):
            if sm.get("from", {}).get("key_code") == "4":
                ident = dev.get("identifiers", {})
                print(f"  device simple_modification ({ident.get('vendor_id')}/{ident.get('product_id')}):")
                print(f"    4 -> {json.dumps(sm.get('to'))}")
EOF
