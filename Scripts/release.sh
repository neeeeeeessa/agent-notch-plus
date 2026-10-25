#!/usr/bin/env bash
set -euo pipefail

# Sign, notarize, and publish Agent Notch Plus from this Mac.
#
#   Scripts/release.sh v1.2
#
# GitHub Releases host the zip. GitHub Pages (branch gh-pages) hosts the
# Sparkle feed. The Developer ID certificate, the notary credentials and the
# Sparkle private key stay in this Mac's keychain.
#
# One-time setup, all kept out of git:
#   .env                      TEAM_ID=<your 10-character Apple team ID>
#   Developer ID Application  Xcode > Settings > Accounts > Manage Certificates
#   notary credentials        xcrun notarytool store-credentials agent-notch-plus
#   Sparkle key               generate_keys --account agent-notch-plus

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

REPO="neeeeeeessa/agent-notch-plus"
REMOTE_URL="https://github.com/${REPO}.git"
FEED_URL="https://neeeeeeessa.github.io/agent-notch-plus/appcast.xml"
PUBLIC_ED_KEY="OVOseJWolEBtafbEXSYl16amj/5gMk0CBPvPOFSjPP4="
SPARKLE_ACCOUNT="agent-notch-plus"
NOTARY_PROFILE="${NOTARY_PROFILE:-agent-notch-plus}"
TEAM_ID="${TEAM_ID:-}"

TAG="${1:-}"
if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "usage: $0 vMAJOR.MINOR[.PATCH]" >&2
  exit 1
fi
VERSION="${TAG#v}"
BUILD="$(date -u +%Y%m%d%H%M)"
PREFIX="https://github.com/${REPO}/releases/download/${TAG}/"

[[ -n "$TEAM_ID" ]] || { echo "Set TEAM_ID in .env" >&2; exit 1; }

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Working tree has changes; commit them first." >&2
  exit 1
fi
published="$(git ls-remote "$REMOTE_URL" refs/heads/main | cut -f1)"
if [[ "$(git rev-parse HEAD)" != "$published" ]]; then
  echo "HEAD is not what ${REPO} main has. Push first, then release." >&2
  exit 1
fi
if [[ -n "$(git ls-remote --tags "$REMOTE_URL" "refs/tags/${TAG}")" ]]; then
  echo "Tag ${TAG} already exists on ${REPO}." >&2
  exit 1
fi
identities="$(security find-identity -v -p codesigning)"
if ! grep -q "Developer ID Application: .*(${TEAM_ID})" <<<"$identities"; then
  echo "No Developer ID Application certificate for team ${TEAM_ID} in the keychain." >&2
  exit 1
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "No notary credentials named ${NOTARY_PROFILE}. Run:" >&2
  echo "  xcrun notarytool store-credentials ${NOTARY_PROFILE}" >&2
  exit 1
fi

DIST="$ROOT/dist"
ARCHIVE="$DIST/AgentNotch.xcarchive"
EXPORT="$DIST/export"
APP="$EXPORT/AgentNotch.app"
UPDATES="$DIST/updates"
ZIP="$UPDATES/AgentNotchPlus.zip"
WT="$DIST/gh-pages"

cleanup() { git worktree remove --force "$WT" >/dev/null 2>&1 || true; }
trap cleanup EXIT

rm -rf "$DIST"
mkdir -p "$EXPORT" "$UPDATES"

echo "Archiving ${VERSION} (${BUILD})…"
xcodebuild archive \
  -project AgentNotch.xcodeproj \
  -scheme AgentNotch \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$DIST/DerivedData" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp"

cat > "$DIST/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>teamID</key><string>${TEAM_ID}</string>
	<key>signingStyle</key><string>manual</string>
	<key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
EOF

echo "Exporting…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist "$DIST/ExportOptions.plist"

PLIST="$APP/Contents/Info.plist"
check() {
  local key="$1" expected="$2" actual
  actual="$(/usr/libexec/PlistBuddy -c "Print :${key}" "$PLIST")"
  [[ "$actual" == "$expected" ]] || { echo "${key} is ${actual}, expected ${expected}" >&2; exit 1; }
}
check CFBundleShortVersionString "$VERSION"
check CFBundleVersion "$BUILD"
check CFBundleIdentifier "io.github.neeeeeeessa.AgentNotchPlus"
check SUFeedURL "$FEED_URL"
check SUPublicEDKey "$PUBLIC_ED_KEY"
# Captured first: with pipefail, grep -q closing the pipe early would fail the check.
authority="$(codesign -dvv "$APP" 2>&1 || true)"
grep -q "Developer ID Application: .*(${TEAM_ID})" <<<"$authority" \
  || { echo "Exported app is not signed with Developer ID for team ${TEAM_ID}" >&2; exit 1; }

echo "Notarizing…"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/notary.zip"
xcrun notarytool submit "$DIST/notary.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv -t install "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "Writing the feed…"
git fetch "$REMOTE_URL" gh-pages:gh-pages 2>/dev/null || true
if git show-ref --verify --quiet refs/heads/gh-pages; then
  git worktree add "$WT" gh-pages
else
  git worktree add --detach "$WT" HEAD
  git -C "$WT" checkout -q --orphan gh-pages
  git -C "$WT" rm -rfq . >/dev/null 2>&1 || true
fi
[[ -f "$WT/appcast.xml" ]] && cp "$WT/appcast.xml" "$UPDATES/appcast.xml"
"$DIST/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" \
  --account "$SPARKLE_ACCOUNT" \
  --download-url-prefix "$PREFIX" \
  --link "https://github.com/${REPO}" \
  --maximum-deltas 0 \
  "$UPDATES"
grep -q "<sparkle:version>${BUILD}</sparkle:version>" "$UPDATES/appcast.xml" \
  || { echo "The feed does not list build ${BUILD}" >&2; exit 1; }
cp "$UPDATES/appcast.xml" "$WT/appcast.xml"
touch "$WT/.nojekyll"
git -C "$WT" add appcast.xml .nojekyll
git -C "$WT" commit -qm "Feed: ${TAG}"

echo "Publishing ${TAG}…"
gh release create "$TAG" "$ZIP" --repo "$REPO" --target "$published" --title "Agent Notch Plus ${VERSION}" --generate-notes
git -C "$WT" push -q "$REMOTE_URL" HEAD:gh-pages

echo "Waiting for the live feed…"
for _ in $(seq 1 36); do
  live="$(curl -fsSL "$FEED_URL" 2>/dev/null || true)"
  if grep -q "<sparkle:version>${BUILD}</sparkle:version>" <<<"$live"; then
    echo "Released ${TAG}."
    echo "Download: ${PREFIX}AgentNotchPlus.zip"
    echo "Feed:     ${FEED_URL}"
    exit 0
  fi
  sleep 10
done
echo "The release is up, but ${FEED_URL} does not list build ${BUILD} yet. Check GitHub Pages for ${REPO}." >&2
exit 1
