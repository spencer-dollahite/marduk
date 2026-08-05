#!/bin/bash
# Marduk release pipeline — run on the Mac from the repo root:
#
#   ./scripts/release.sh 0.3.0
#
# Flow: bump Version.swift → commit + tag + push → wait for CI green →
# release build → assemble bundle → Developer ID sign (hardened runtime,
# secure timestamp, Apple-Events entitlement) → notarize → staple →
# zip → publish GitHub Release with commit-derived notes → update the
# Homebrew tap (spencer-dollahite/homebrew-marduk) with the new cask.
#
# Requires: a "Developer ID Application" certificate in the keychain,
# a notarytool keychain profile (default "marduk-notary"; override with
# MARDUK_NOTARY_PROFILE), and the gh CLI authenticated.
set -euo pipefail

VERSION="${1:?usage: release.sh <version, e.g. 0.3.0>}"
PROFILE="${MARDUK_NOTARY_PROFILE:-marduk-notary}"

[[ -f Package.swift ]] || { echo "error: run from the repo root" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "error: working tree not clean" >&2; exit 1; }

# Sync with origin BEFORE bumping/tagging: a commit pushed from another
# machine mid-release once left the tag pointing at an orphaned commit
# (the push raced and lost, but the tag went through). --ff-only can
# only advance; on divergence it fails here, before anything is stamped.
echo "==> Syncing with origin"
git pull --ff-only origin main

# Monotonic guard: an older-but-never-tagged version would fully
# succeed and poison everything downstream (releases/latest goes by
# creation date, brew would see installed users as "ahead", and the
# self-updater offers any tag != running version — a downgrade party).
CURRENT=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/App/Version.swift)
NEWEST_TAG=$(git tag --list 'v*' | sed 's/^v//' | sort -V | tail -1)
for BASE in "$CURRENT" "$NEWEST_TAG"; do
    [[ -z "$BASE" ]] && continue
    HIGHEST=$(printf '%s\n%s\n' "$BASE" "$VERSION" | sort -V | tail -1)
    if [[ "$HIGHEST" != "$VERSION" || "$BASE" == "$VERSION" ]]; then
        echo "error: version $VERSION is not greater than $BASE" >&2
        exit 1
    fi
done

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
# ASSEMBLE OUTSIDE THE REPO. Everything below re-signs and staples this
# bundle, and the default path (<repo>/Marduk.app) is the bundle launchd is
# executing from on a source install. `codesign --force` rewrites the
# executable in place, which invalidates a running process's code pages and
# brings the daemon back as code macOS will not vouch for: Accessibility
# denied, event tap dead, and the 10s tap-retry cannot heal it because the
# process's identity was settled at exec. The only cure was removing the
# Accessibility entry and re-adding it — which works because revoking a
# grant KILLS the process, forcing a genuinely fresh start (toggling the
# entry off and on does not, which is exactly why it never helped).
# Field-confirmed 2026-07-25: every `dd` release cost the grant.
BUILD_DIR=$(mktemp -d -t marduk-release)
trap 'rm -rf "$BUILD_DIR"' EXIT
.build/release/marduk bundle --output "$BUILD_DIR" > /dev/null
APP="$BUILD_DIR/Marduk.app"
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

echo "==> Notarizing the app (this usually takes a few minutes)"
ZIP="$(mktemp -t marduk-notarize).zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
rm -f "$ZIP"
xcrun stapler staple "$APP"
spctl -a -vv --type execute "$APP"

echo "==> Building the disk image (drag-to-Applications)"
# Constant asset name: the README's one-click link
# releases/latest/download/Marduk.dmg depends on it (gh names the asset
# after the basename). Version lives in the tag, the release title, and
# the volume name. Built in a temp dir, NEVER the repo root — the
# 0.4.17 run died mid-notarization and its leftover DMG tripped the
# clean-tree guard on the next cut (field 2026-08-05).
DMG_DIR=$(mktemp -d -t marduk-dmg-out)
DMG="$DMG_DIR/Marduk.dmg"
STAGE=$(mktemp -d -t marduk-dmg)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Marduk $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "==> Signing + notarizing the disk image"
codesign --force --timestamp --sign "Developer ID Application" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> Publishing GitHub release"
PREV_TAG=$(git describe --tags --abbrev=0 "v$VERSION^" 2>/dev/null || true)
if [[ -n "$PREV_TAG" ]]; then RANGE="$PREV_TAG..v$VERSION"; else RANGE="v$VERSION"; fi
NOTES=$(git log --format='- %s' "$RANGE" | head -40)
gh release create "v$VERSION" "$DMG" --title "Marduk $VERSION" --notes "$NOTES

---
**Install:** download \`Marduk.dmg\`, open it, drag **Marduk** into **Applications**, then open Marduk from Applications. It installs itself and talks you through the rest — no Terminal, no Xcode.

Or with Homebrew: \`brew install --cask spencer-dollahite/marduk/marduk\`"

echo "==> Updating Homebrew tap"
# The cask pins the VERSIONED asset URL (releases/download/v$VERSION/),
# never the floating releases/latest link — the sha256 must keep
# matching the bytes the URL serves. Runs before the local DMG is
# deleted, and after the release exists (so the URL is live).
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
TAP=$(mktemp -d -t marduk-tap)
gh repo clone spencer-dollahite/homebrew-marduk "$TAP" -- --depth 1
mkdir -p "$TAP/Casks"
cat > "$TAP/Casks/marduk.rb" <<CASK
cask "marduk" do
  version "$VERSION"
  sha256 "$SHA"

  # Marduk self-updates (u/uu and the periodic timer swap the bundle in
  # place) — Chrome-style: brew leaves the version alone unless --greedy
  auto_updates true

  url "https://github.com/spencer-dollahite/marduk/releases/download/v#{version}/Marduk.dmg"
  name "Marduk"
  desc "Audio-first assistive platform for macOS with Vim-style modal navigation"
  homepage "https://github.com/spencer-dollahite/marduk"

  depends_on macos: ">= :tahoe"

  app "Marduk.app"
  binary "#{appdir}/Marduk.app/Contents/MacOS/marduk"

  caveats <<~EOS
    Open Marduk from Applications — it installs itself and talks you
    through the rest, including the Accessibility permission.
  EOS

  uninstall launchctl: "com.marduk.daemon"
  zap trash: [
    "~/.config/marduk",
    "~/Library/LaunchAgents/com.marduk.daemon.plist",
    "~/Library/Logs/marduk.log",
  ]
end
CASK
git -C "$TAP" add Casks/marduk.rb
git -C "$TAP" commit -m "marduk $VERSION"
git -C "$TAP" push
rm -rf "$TAP"

rm -rf "$DMG_DIR"
rm -f "$ENT"
echo "==> Done: https://github.com/spencer-dollahite/marduk/releases/tag/v$VERSION"
