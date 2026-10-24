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
command -v gh >/dev/null || die "gh is not installed"
gh auth status >/dev/null 2>&1 || die "gh is not logged in (run: gh auth login)"
[[ -f "$CASK" ]] || die "$CASK is missing"

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

# --- Publish -----------------------------------------------------------------------------------------
step "Tagging $TAG and pushing the tag"
git tag -a "$TAG" -m "Hearsay $WANT"
git push origin "$TAG"

step "Creating GitHub release $TAG"
gh release create "$TAG" "$ZIP" --title "Hearsay $WANT" --generate-notes --verify-tag

# --- Cask ----------------------------------------------------------------------------------------------
step "Updating $CASK"
sed -i '' -E "s/^  version \".*\"/  version \"$WANT\"/" "$CASK"
sed -i '' -E "s/^  sha256 .*/  sha256 \"$SHA\"/" "$CASK"
grep -q "version \"$WANT\"" "$CASK" || die "cask version rewrite failed"
grep -q "sha256 \"$SHA\"" "$CASK" || die "cask sha256 rewrite failed"

echo
echo "Released $TAG. Next: commit $CASK, then copy it into vrennat/homebrew-tap (docs/RELEASING.md)."
