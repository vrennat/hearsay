#!/bin/bash
# Build the Mac App Store package: sandboxed Hearsay.app signed with Apple Distribution, wrapped by
# productbuild into Hearsay-<version>.pkg signed with the installer certificate, optionally uploaded.
# Usage: scripts/package-mas.sh [--upload]
# Needs (docs/APP-STORE.md):
#   - "Apple Distribution: Tanner Vass (4Q8P5YMHPK)" and
#     "3rd Party Mac Developer Installer: Tanner Vass (4Q8P5YMHPK)" in the login keychain
#   - HEARSAY_PROVISION_PROFILE: a Mac App Store provisioning profile for com.tannervass.hearsay
#   - for --upload: ASC_KEY_ID with the key at
#     ~/.appstoreconnect/private_keys/AuthKey_<id>.p8, and ASC_ISSUER_ID
set -euo pipefail

UPLOAD=0
[[ "${1:-}" == "--upload" ]] && UPLOAD=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
TEAM="Tanner Vass (4Q8P5YMHPK)"
APP_IDENTITY="Apple Distribution: $TEAM"
PKG_IDENTITY="3rd Party Mac Developer Installer: $TEAM"
: "${HEARSAY_PROVISION_PROFILE:?Set HEARSAY_PROVISION_PROFILE to the Mac App Store provisioning profile}"
for id in "$APP_IDENTITY" "$PKG_IDENTITY"; do
  security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$id" \
    || security find-identity -v 2>/dev/null | grep -Fq "$id" \
    || { echo "error: certificate not in keychain: $id" >&2; exit 1; }
done
if [[ -n "$(git status --porcelain)" ]]; then echo "error: dirty tree" >&2; exit 1; fi

VERSION="$(tr -d '[:space:]' < VERSION)"
HEARSAY_SIGN_IDENTITY="$APP_IDENTITY" scripts/build-app.sh --mas --no-install
APP="$ROOT/.build/app/Hearsay.app"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.application-identifier" \
  || { echo "error: the app has no application-identifier entitlement; was the profile embedded?" >&2; exit 1; }

OUT="$ROOT/dist"
mkdir -p "$OUT"
PKG="$OUT/Hearsay-$VERSION.pkg"
rm -f "$PKG"
productbuild --component "$APP" /Applications --sign "$PKG_IDENTITY" --product "$APP/Contents/Info.plist" "$PKG"
pkgutil --check-signature "$PKG" | head -3
echo "Built $PKG"

if (( UPLOAD )); then
  KEY_ID="${ASC_KEY_ID:?set ASC_KEY_ID}"
  : "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID (App Store Connect, Users and Access, Integrations)}"
  xcrun altool --validate-app -f "$PKG" -t macos --apiKey "$KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
  xcrun altool --upload-app -f "$PKG" -t macos --apiKey "$KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
  echo "Uploaded; it appears under TestFlight / App Store Connect in a few minutes."
fi
