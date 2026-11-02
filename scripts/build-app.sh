#!/bin/bash
# Release build, assemble and sign Hearsay.app, install to /Applications and the CLI to ~/.local/bin/hearsay.
# Usage: scripts/build-app.sh [--debug] [--no-install]
#   --debug       adds get-task-allow for lldb; never ship it
#   --no-install  build and sign .build/app/Hearsay.app only; leave /Applications and ~/.local/bin alone
# Environment:
#   HEARSAY_SIGN_IDENTITY   codesign identity; default Developer ID.
set -euo pipefail

DEBUG=0
INSTALL=1
for arg in "$@"; do
  case "$arg" in
    --debug) DEBUG=1 ;;
    --no-install) INSTALL=0 ;;
    *) echo "usage: $0 [--debug] [--no-install]" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
IDENTITY="${HEARSAY_SIGN_IDENTITY:-Developer ID Application: Tanner Vass (4Q8P5YMHPK)}"
BUNDLE_ID="com.tannervass.hearsay"
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
# HEARSAY_BUILD_NUMBER overrides the commit count (scripts/release.sh reads the same variable).
BUILD="${HEARSAY_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

# --- Build -------------------------------------------------------------------------------------
BUILD_ROOT="${HEARSAY_BUILD_ROOT:-$ROOT/.build}"
SWIFT_FLAGS=(--scratch-path "$BUILD_ROOT" --jobs "${HEARSAY_BUILD_JOBS:-2}")
swift build -c release --product Hearsay ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}
swift build -c release --product hearsay-cli ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}
BIN="$(swift build -c release --show-bin-path ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"})"

STAGE="$BUILD_ROOT/app"
APP="$STAGE/Hearsay.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Hearsay" "$APP/Contents/MacOS/Hearsay"
# The CLI ships inside the bundle too: the Homebrew cask and Settings -> Agents symlink this copy.
cp "$BIN/hearsay-cli" "$APP/Contents/MacOS/hearsay-cli"

# SwiftPM resource bundles: the generated Bundle.module checks Bundle.main.resourceURL first.
shopt -s nullglob
for b in "$BIN"/*.bundle; do
  case "$(basename "$b")" in *Tests.bundle) continue ;; esac
  cp -R "$b" "$APP/Contents/Resources/"
done
# Dynamic frameworks: Sparkle (FluidAudio links statically).
frameworks=("$BIN"/*.framework)
if (( ${#frameworks[@]} )); then
  mkdir -p "$APP/Contents/Frameworks"
  for f in "${frameworks[@]}"; do cp -R "$f" "$APP/Contents/Frameworks/"; done
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Hearsay" 2>/dev/null || true
fi
shopt -u nullglob

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
if [[ -s "$SPARKLE_PUBKEY_FILE" ]]; then
  SPARKLE_KEYS="  <key>SUFeedURL</key><string>https://github.com/vrennat/hearsay/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>$(tr -d '[:space:]' < "$SPARKLE_PUBKEY_FILE")</string>
  <key>SUEnableAutomaticChecks</key><true/>"
else
  echo "note: no $SPARKLE_PUBKEY_FILE, so this build cannot update itself" >&2
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
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
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
# Nested CLI first (the app's signature seals it).
codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$APP/Contents/MacOS/hearsay-cli"
codesign --force --options runtime "$TIMESTAMP" --entitlements "$ENT" --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# --- Install -----------------------------------------------------------------------------------
if (( ! INSTALL )); then
  echo "Built $APP ($VERSION build $BUILD); not installed"
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
