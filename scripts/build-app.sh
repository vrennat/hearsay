#!/bin/bash
# Release build, assemble and sign Hearsay.app, install to /Applications and the CLI to ~/.local/bin/hearsay.
# Usage: scripts/build-app.sh [--debug] [--mas] [--no-install]
#   --debug       adds get-task-allow for lldb; never ship it
#   --mas         App Store flavour: HSDistribution=appStore and App Sandbox entitlements. With
#                 HEARSAY_PROVISION_PROFILE set, the profile is embedded and the application-identifier
#                 and team-identifier entitlements the store requires are added (without a profile AMFI
#                 kills an app carrying them, so they are never added to a Developer ID build).
#   --no-install  build and sign .build/app/Hearsay.app only; leave /Applications and ~/.local/bin alone
# Environment:
#   HEARSAY_SIGN_IDENTITY   codesign identity; default Developer ID. scripts/package-mas.sh passes
#                           "Apple Distribution: Tanner Vass (4Q8P5YMHPK)".
#   HEARSAY_PROVISION_PROFILE  path of a Mac App Store provisioning profile for com.tannervass.hearsay.
set -euo pipefail

DEBUG=0
MAS=0
INSTALL=1
for arg in "$@"; do
  case "$arg" in
    --debug) DEBUG=1 ;;
    --mas) MAS=1 ;;
    --no-install) INSTALL=0 ;;
    *) echo "usage: $0 [--debug] [--mas] [--no-install]" >&2; exit 2 ;;
  esac
done
DISTRIBUTION=developerID
if (( MAS )); then DISTRIBUTION=appStore; fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
IDENTITY="${HEARSAY_SIGN_IDENTITY:-Developer ID Application: Tanner Vass (4Q8P5YMHPK)}"
TEAM_ID="4Q8P5YMHPK"
BUNDLE_ID="com.tannervass.hearsay"
PROFILE="${HEARSAY_PROVISION_PROFILE:-}"
# Notarization rejects signatures without a secure timestamp; debug builds stay offline-friendly.
TIMESTAMP="--timestamp"
if (( DEBUG )); then TIMESTAMP=""$TIMESTAMP""; fi
INSTALL_APP="/Applications/Hearsay.app"
CLI_DEST="$HOME/.local/bin/hearsay"
LOCK="$HOME/Library/Application Support/Hearsay/recording.pid"

# --- Refuse while a meeting is recording -------------------------------------------------------
# The app holds LOCK (its pid) while any instance records, including --root test instances.
# Only installing replaces the running app; a --no-install build skips the check.
if (( INSTALL )) && [[ -f "$LOCK" ]]; then
  pid="$(tr -dc '0-9' < "$LOCK")"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "error: Hearsay (pid $pid) is recording; stop it first." >&2
    exit 1
  fi
fi
if (( INSTALL )) && [[ -d "$HOME/Meetings" ]]; then
  for f in "$HOME/Meetings"/*/meeting.json; do
    [[ -f "$f" ]] || continue
    if grep -Eq '"status"[[:space:]]*:[[:space:]]*"recording"' "$f"; then
      if pgrep -x Hearsay >/dev/null; then
        echo "error: a meeting is recording: $f" >&2
        exit 1
      fi
      echo "note: $f says recording but Hearsay is not running; the next launch marks it interrupted."
    fi
  done
fi

# --- Version -----------------------------------------------------------------------------------
if [[ -f VERSION ]]; then
  VERSION="$(tr -d '[:space:]' < VERSION)"
else
  VERSION="$(git describe --tags --always 2>/dev/null || echo 0.0.0)"
fi
# HEARSAY_BUILD_NUMBER overrides the commit count: App Store Connect never accepts a build number twice.
BUILD="${HEARSAY_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

# --- Build -------------------------------------------------------------------------------------
# The App Store build compiles the updater out and drops the unused Sparkle load command; the store
# updates it, and a self-updater would be rejected.
SWIFT_FLAGS=()
if (( MAS )); then SWIFT_FLAGS=(-Xswiftc -DHEARSAY_NO_SPARKLE -Xlinker -dead_strip_dylibs); fi
swift build -c release --product Hearsay ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}
swift build -c release --product hearsay-cli ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}
BIN="$(swift build -c release --show-bin-path ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"})"

STAGE="$ROOT/.build/app"
APP="$STAGE/Hearsay.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Hearsay" "$APP/Contents/MacOS/Hearsay"
# The CLI ships inside the bundle too: the store build cannot install to ~/.local/bin, and Settings ->
# "Give your agents access" points a symlink at this copy.
cp "$BIN/hearsay-cli" "$APP/Contents/MacOS/hearsay-cli"

# SwiftPM resource bundles: the generated Bundle.module checks Bundle.main.resourceURL first.
shopt -s nullglob
for b in "$BIN"/*.bundle; do
  case "$(basename "$b")" in *Tests.bundle) continue ;; esac
  cp -R "$b" "$APP/Contents/Resources/"
done
# Dynamic frameworks: Sparkle (Developer ID only; FluidAudio links statically).
frameworks=()
for f in "$BIN"/*.framework; do
  if (( MAS )) && [[ "$(basename "$f")" == Sparkle.framework ]]; then continue; fi
  frameworks+=("$f")
done
if (( MAS )) && otool -L "$BIN/Hearsay" | grep -q Sparkle.framework; then
  echo "error: the App Store binary still links Sparkle" >&2; exit 1
fi
if (( ${#frameworks[@]} )); then
  mkdir -p "$APP/Contents/Frameworks"
  for f in "${frameworks[@]}"; do cp -R "$f" "$APP/Contents/Frameworks/"; done
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Hearsay" 2>/dev/null || true
fi
shopt -u nullglob
# Privacy manifest: no tracking, no collected data, reasons for UserDefaults and file timestamps.
cp "$ROOT/Resources/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
if (( MAS )) && [[ -n "$PROFILE" ]]; then
  [[ -f "$PROFILE" ]] || { echo "error: no provisioning profile at $PROFILE" >&2; exit 1; }
  cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
fi

# App icon: actool compiles the Icon Composer document to Assets.car (Liquid Glass renditions for
# macOS 26+) and AppIcon.icns (flat fallback for Finder/Quick Look); the partial plist must say
# CFBundleIconName/CFBundleIconFile = AppIcon, which the Info.plist below hardcodes.
ICON_PARTIAL="$STAGE/AppIcon-partial.plist"
xcrun actool "$ROOT/Resources/AppIcon.icon" --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon --output-partial-info-plist "$ICON_PARTIAL" \
  --errors --warnings --output-format human-readable-text >/dev/null
for f in Assets.car AppIcon.icns; do
  [[ -f "$APP/Contents/Resources/$f" ]] || { echo "error: actool did not produce $f" >&2; exit 1; }
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$ICON_PARTIAL")" == AppIcon ]] || { echo "error: unexpected actool partial plist" >&2; exit 1; }

# Sparkle: feed = the latest release's appcast.xml; public key from Resources/sparkle-public-key.txt
# (the private half lives in the release Mac's login Keychain, made by Sparkle's generate_keys).
SPARKLE_KEYS=""
SPARKLE_PUBKEY_FILE="$ROOT/Resources/sparkle-public-key.txt"
if (( ! MAS )); then
  if [[ -s "$SPARKLE_PUBKEY_FILE" ]]; then
    SPARKLE_KEYS="  <key>SUFeedURL</key><string>https://github.com/vrennat/hearsay/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>$(tr -d '[:space:]' < "$SPARKLE_PUBKEY_FILE")</string>
  <key>SUEnableAutomaticChecks</key><true/>"
  else
    echo "note: no $SPARKLE_PUBKEY_FILE, so this build cannot update itself" >&2
  fi
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Hearsay</string>
  <key>CFBundleDisplayName</key><string>Hearsay</string>
  <key>CFBundleExecutable</key><string>Hearsay</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Hearsay records your side of meetings and transcribes them on this Mac.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Hearsay records call audio from other apps so both sides of a meeting are transcribed on this Mac.</string>
  <key>HSDistribution</key><string>$DISTRIBUTION</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Hearsay reads the current calendar event to title meetings and list attendees.</string>
$SPARKLE_KEYS
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

ENT="$STAGE/Hearsay.entitlements"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  echo '<plist version="1.0"><dict>'
  echo '  <key>com.apple.security.device.audio-input</key><true/>'
  # Hardened runtime: without this the Developer ID build's calendar request is refused with no prompt.
  echo '  <key>com.apple.security.personal-information.calendars</key><true/>'
  if (( MAS )); then
    echo '  <key>com.apple.security.app-sandbox</key><true/>'
    echo '  <key>com.apple.security.network.client</key><true/>'
    echo '  <key>com.apple.security.files.user-selected.read-write</key><true/>'
    echo '  <key>com.apple.security.files.bookmarks.app-scope</key><true/>'
    if [[ -n "$PROFILE" ]]; then
      echo "  <key>com.apple.application-identifier</key><string>$TEAM_ID.$BUNDLE_ID</string>"
      echo "  <key>com.apple.developer.team-identifier</key><string>$TEAM_ID</string>"
    fi
  fi
  if (( DEBUG )); then echo '  <key>com.apple.security.get-task-allow</key><true/>'; fi
  echo '</dict></plist>'
} > "$ENT"
plutil -lint "$ENT" >/dev/null
if (( DEBUG )); then
  echo "WARNING: --debug build carries com.apple.security.get-task-allow. Never ship it." >&2
fi

if [[ -d "$APP/Contents/Frameworks" ]]; then
  for f in "$APP/Contents/Frameworks"/*; do
    # Sparkle's helpers are signed inside out, never with --deep (Sparkle's sandboxing guide).
    if [[ "$(basename "$f")" == Sparkle.framework ]]; then
      S="$f/Versions/B"
      codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$S/XPCServices/Installer.xpc"
      codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" --preserve-metadata=entitlements "$S/XPCServices/Downloader.xpc"
      codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$S/Autoupdate"
      codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$S/Updater.app"
    fi
    codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$f"
  done
fi
# Nested CLI first (the app's signature seals it). In the sandbox it inherits the app's sandbox.
CLI_ENT="$STAGE/hearsay-cli.entitlements"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  echo '<plist version="1.0"><dict>'
  if (( MAS )); then
    echo '  <key>com.apple.security.app-sandbox</key><true/>'
    echo '  <key>com.apple.security.inherit</key><true/>'
  fi
  echo '</dict></plist>'
} > "$CLI_ENT"
codesign --force --options runtime "$TIMESTAMP" --entitlements "$CLI_ENT" --sign "$IDENTITY" "$APP/Contents/MacOS/hearsay-cli"
codesign --force --options runtime "$TIMESTAMP" --entitlements "$ENT" --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# --- Install -----------------------------------------------------------------------------------
if (( ! INSTALL )); then
  echo "Built $APP ($VERSION build $BUILD, $DISTRIBUTION); not installed"
  exit 0
fi
if pgrep -x Hearsay >/dev/null; then
  echo "Stopping running Hearsay"
  pkill -x Hearsay || true
  for _ in $(seq 1 50); do pgrep -x Hearsay >/dev/null || break; /bin/sleep 0.1; done
  if pgrep -x Hearsay >/dev/null; then pkill -9 -x Hearsay || true; fi
fi
rm -rf "$INSTALL_APP"
cp -R "$APP" "$INSTALL_APP"

mkdir -p "$(dirname "$CLI_DEST")"
cp "$BIN/hearsay-cli" "$CLI_DEST.tmp"
codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$CLI_DEST.tmp"
mv -f "$CLI_DEST.tmp" "$CLI_DEST"

echo "Installed $INSTALL_APP ($VERSION build $BUILD) and $CLI_DEST"
