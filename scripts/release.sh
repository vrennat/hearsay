#!/bin/bash
# Build, notarize and publish a Developer ID release of Hearsay, then update Casks/hearsay.rb.
# Usage: scripts/release.sh <version>    (VERSION must already say <version> and be committed)
# One-time setup and the tap workflow: docs/RELEASING.md.
set -euo pipefail

if [[ $# -ne 1 ]]; then echo "usage: $0 <version>" >&2; exit 2; fi
WANT="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
PROFILE="hearsay-notary"
TAG="v$WANT"
CASK="Casks/hearsay.rb"

step() { echo; echo "==> $*"; }
die() { echo "error: $*" >&2; exit 1; }

# --- Preconditions -------------------------------------------------------------------------------
step "Checking the tree and VERSION"
[[ -z "$(git status --porcelain)" ]] || die "working tree is dirty; commit first"
HAVE="$(tr -d '[:space:]' < VERSION)"
[[ "$HAVE" == "$WANT" ]] || die "VERSION says $HAVE, not $WANT"
grep -q "public static let version = \"$WANT\"" Sources/HearsayCore/Support/Version.swift \
  || die "HearsayCore.version does not say $WANT (Sources/HearsayCore/Support/Version.swift)"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then die "tag $TAG already exists"; fi
# Sparkle orders updates by CFBundleVersion = commit count of HEAD. A release cut from a branch (whose
# unsquashed commits count higher than main will for a while) would leave later releases offered to nobody.
[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || die "release from main, not $(git rev-parse --abbrev-ref HEAD)"
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "main is not origin/main; pull or push first"
# The build number build-app.sh will use, compared with the live feed before the long notarization wait.
WANT_BUILD="${HEARSAY_BUILD_NUMBER:-$(git rev-list --count HEAD)}"
FEED_FILE="$(mktemp)"
FEED_STATUS="$(curl -sL -o "$FEED_FILE" -w '%{http_code}' https://github.com/vrennat/hearsay/releases/latest/download/appcast.xml || true)"
case "$FEED_STATUS" in
  200)
    LIVE="$(sed -n 's:.*<sparkle\:version>\([0-9]*\)</sparkle\:version>.*:\1:p' "$FEED_FILE" | head -1 || true)"
    [[ -n "$LIVE" ]] || die "the live appcast.xml has no sparkle:version"
    (( WANT_BUILD > LIVE )) || die "build $WANT_BUILD is not newer than the live appcast's $LIVE; Sparkle would offer it to nobody"
    echo "live appcast build $LIVE, this release $WANT_BUILD" ;;
  404) echo "no live appcast.xml (first release with Sparkle)" ;;
  *) die "could not fetch the live appcast.xml (HTTP '$FEED_STATUS'); check the network and retry" ;;
esac
rm -f "$FEED_FILE"
command -v gh >/dev/null || die "gh is not installed"
gh auth status >/dev/null 2>&1 || die "gh is not logged in (run: gh auth login)"
[[ -f "$CASK" ]] || die "$CASK is missing"
[[ -s Resources/sparkle-public-key.txt ]] || die "Resources/sparkle-public-key.txt is missing (docs/RELEASING.md, Sparkle keys)"

# --- Build -----------------------------------------------------------------------------------------
step "Building with scripts/build-app.sh"
scripts/build-app.sh
APP="$ROOT/.build/app/Hearsay.app"   # build-app.sh stages the signed bundle here before installing it
[[ -d "$APP" ]] || die "no staged bundle at $APP"
[[ -x "$APP/Contents/MacOS/hearsay-cli" ]] || die "$APP has no Contents/MacOS/hearsay-cli; the cask links it"
codesign --verify --strict --verbose=2 "$APP"

OUT="$ROOT/.build/release"
ZIP="$OUT/Hearsay-$WANT.zip"
mkdir -p "$OUT"
rm -f "$ZIP"

# --- Notarize ----------------------------------------------------------------------------------------
step "Zipping for notarization"
ditto -c -k --keepParent "$APP" "$ZIP"

step "Submitting to the Apple notary service (profile $PROFILE); this waits"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait | tee "$OUT/notary-$WANT.log"
grep -q "status: Accepted" "$OUT/notary-$WANT.log" \
  || die "notarization not accepted; run: xcrun notarytool log <submission id> --keychain-profile $PROFILE"

step "Stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

step "Re-zipping the stapled app"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "sha256 $SHA"

# --- Appcast ---------------------------------------------------------------------------------------
# One item, the release being published: Sparkle offers the newest build to everyone older. The EdDSA
# signature uses the private key in this Mac's login Keychain (Sparkle's generate_keys).
step "Signing the update and writing appcast.xml"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
[[ -x "$SPARKLE_BIN/sign_update" ]] || die "no $SPARKLE_BIN/sign_update; run swift package resolve"
SIG="$("$SPARKLE_BIN/sign_update" "$ZIP")" || die "sign_update failed (is the Sparkle private key in the Keychain?)"
[[ "$SIG" == *edSignature=* ]] || die "sign_update printed no signature: $SIG"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
[[ "$BUILD" == "$WANT_BUILD" ]] || die "built CFBundleVersion $BUILD, expected $WANT_BUILD"
APPCAST="$OUT/appcast.xml"
cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Hearsay</title>
    <item>
      <title>Hearsay $WANT</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$WANT</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/vrennat/hearsay/releases/tag/$TAG</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/vrennat/hearsay/releases/download/$TAG/Hearsay-$WANT.zip" $SIG type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$APPCAST" || die "appcast.xml is not valid XML"

# --- Publish -----------------------------------------------------------------------------------------
step "Tagging $TAG and pushing the tag"
git tag -a "$TAG" -m "Hearsay $WANT"
git push origin "$TAG"

step "Creating GitHub release $TAG"
gh release create "$TAG" "$ZIP" "$APPCAST" --title "Hearsay $WANT" --generate-notes --verify-tag

# --- Cask ----------------------------------------------------------------------------------------------
step "Updating $CASK"
sed -i '' -E "s/^  version \".*\"/  version \"$WANT\"/" "$CASK"
sed -i '' -E "s/^  sha256 .*/  sha256 \"$SHA\"/" "$CASK"
grep -q "version \"$WANT\"" "$CASK" || die "cask version rewrite failed"
grep -q "sha256 \"$SHA\"" "$CASK" || die "cask sha256 rewrite failed"

echo
echo "Released $TAG. Next: commit $CASK, then copy it into vrennat/homebrew-tap (docs/RELEASING.md)."
