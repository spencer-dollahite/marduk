#!/bin/bash
# Marduk release pipeline — run on the Mac from the repo root:
#
#   ./scripts/release.sh 0.3.0
#
# Flow: bump Version.swift → commit + tag + push → wait for CI green →
# release build → assemble bundle → Developer ID sign (hardened runtime,
# secure timestamp, Apple-Events entitlement) → notarize → staple →
# zip → publish GitHub Release with commit-derived notes.
#
# Requires: a "Developer ID Application" certificate in the keychain,
# a notarytool keychain profile (default "marduk-notary"; override with
# MARDUK_NOTARY_PROFILE), and the gh CLI authenticated.
set -euo pipefail

VERSION="${1:?usage: release.sh <version, e.g. 0.3.0>}"
PROFILE="${MARDUK_NOTARY_PROFILE:-marduk-notary}"

[[ -f Package.swift ]] || { echo "error: run from the repo root" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "error: working tree not clean" >&2; exit 1; }

echo "==> Version $VERSION"
sed -i '' "s/static let version = \".*\"/static let version = \"$VERSION\"/" \
    Sources/App/Version.swift
if ! git diff --quiet; then
    git add Sources/App/Version.swift
    git commit -m "Release $VERSION"
fi
git tag "v$VERSION"
git push origin main "v$VERSION"

echo "==> Waiting for CI on the release commit"
sleep 15
RUN_ID=$(gh run list --commit "$(git rev-parse HEAD)" --limit 1 \
    --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN_ID" --exit-status

echo "==> Building (release configuration)"
swift build -c release

echo "==> Assembling bundle"
.build/release/marduk bundle > /dev/null
APP="Marduk.app"
[[ -d "$APP" ]] || { echo "error: bundle assembly failed" >&2; exit 1; }

echo "==> Distribution signing (hardened runtime + timestamp)"
# The bundle assembler's own signature is development-grade
# (--timestamp=none, no hardened runtime) — notarization requires this
# re-sign. The Apple-Events entitlement keeps media control working
# under the hardened runtime.
ENT="$(mktemp -t marduk-entitlements).plist"
cat > "$ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>com.apple.security.automation.apple-events</key><true/>
</dict></plist>
PLIST
codesign --force --options runtime --timestamp \
    --entitlements "$ENT" \
    --identifier com.marduk.daemon \
    --sign "Developer ID Application" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Notarizing (this usually takes a few minutes)"
ZIP="Marduk-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$APP"
spctl -a -vv --type execute "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"   # final zip contains the stapled app

echo "==> Publishing GitHub release"
PREV_TAG=$(git describe --tags --abbrev=0 "v$VERSION^" 2>/dev/null || true)
if [[ -n "$PREV_TAG" ]]; then RANGE="$PREV_TAG..v$VERSION"; else RANGE="v$VERSION"; fi
NOTES=$(git log --format='- %s' "$RANGE" | head -40)
gh release create "v$VERSION" "$ZIP" --title "Marduk $VERSION" --notes "$NOTES

---
**Install:** download \`Marduk-$VERSION.zip\`, unzip, drag \`Marduk.app\` to Applications, then run in Terminal:
\`\`\`
/Applications/Marduk.app/Contents/MacOS/marduk install
\`\`\`
Grant Accessibility to Marduk.app when it asks (it asks out loud). No Xcode needed."

rm -f "$ZIP" "$ENT"
echo "==> Done: https://github.com/spencer-dollahite/marduk/releases/tag/v$VERSION"
