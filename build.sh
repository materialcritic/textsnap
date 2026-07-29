#!/usr/bin/env bash
#
# Builds TextSnap.app. Run from the project root on macOS with Xcode or the
# Command Line Tools installed.
#
#   ./build.sh                  release build, universal binary
#   ./build.sh --debug          faster build, current architecture only
#   ./build.sh --install        also copy the result into /Applications
#   ./build.sh --run            launch it when the build finishes
#
set -euo pipefail

APP_NAME="TextSnap"
BUNDLE_ID="${TEXTSNAP_BUNDLE_ID:-com.example.textsnap}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

CONFIG="release"
UNIVERSAL=1
INSTALL=0
RUN=0

for arg in "$@"; do
	case "$arg" in
		--debug)     CONFIG="debug"; UNIVERSAL=0 ;;
		--install)   INSTALL=1 ;;
		--run)       RUN=1 ;;
		--native)    UNIVERSAL=0 ;;
		-h|--help)   sed -n '2,12p' "$0"; exit 0 ;;
		*)           echo "unknown option: $arg" >&2; exit 1 ;;
	esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
	echo "TextSnap builds on macOS only: it links AppKit, Vision and ScreenCaptureKit." >&2
	exit 1
fi

command -v swift >/dev/null || { echo "swift not found. Install Xcode or the Command Line Tools." >&2; exit 1; }

# ---------------------------------------------------------------- compile

FLAGS=(-c "$CONFIG")
if [[ "$UNIVERSAL" == "1" ]]; then
	FLAGS+=(--arch arm64 --arch x86_64)
fi

echo "==> Building ($CONFIG$( [[ "$UNIVERSAL" == 1 ]] && echo ", universal" ))"
swift build "${FLAGS[@]}"
BIN_DIR="$(swift build "${FLAGS[@]}" --show-bin-path)"
BINARY="$BIN_DIR/$APP_NAME"

[[ -f "$BINARY" ]] || { echo "expected a binary at $BINARY" >&2; exit 1; }

# ---------------------------------------------------------------- bundle

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"
sed "s|__BUNDLE_ID__|$BUNDLE_ID|g" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ---------------------------------------------------------------- icon

if [[ -d "$ROOT/Resources/AppIcon.iconset" ]]; then
	if command -v iconutil >/dev/null; then
		iconutil -c icns "$ROOT/Resources/AppIcon.iconset" \
			-o "$APP/Contents/Resources/AppIcon.icns"
	else
		echo "    iconutil unavailable; shipping without an icon"
	fi
fi

# ---------------------------------------------------------------- sign

# An ad-hoc signature is enough to run and to hold Screen Recording permission.
# macOS keys that permission to the signature, so it must be re-granted whenever
# the binary changes. A real Developer ID certificate avoids that: pass it as
# CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)".
IDENTITY="${CODESIGN_IDENTITY:--}"
echo "==> Signing with identity: $IDENTITY"
codesign --force --sign "$IDENTITY" \
	--identifier "$BUNDLE_ID" \
	--options runtime \
	--timestamp=none \
	"$APP" >/dev/null 2>&1 \
	|| codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"

# ---------------------------------------------------------------- finish

echo "==> Built $APP"

if [[ "$INSTALL" == "1" ]]; then
	echo "==> Installing to /Applications"
	# Quit any running copy so the replacement is clean.
	osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
	pkill -x "$APP_NAME" >/dev/null 2>&1 || true
	sleep 1
	rm -rf "/Applications/$APP_NAME.app"
	cp -R "$APP" "/Applications/$APP_NAME.app"
	APP="/Applications/$APP_NAME.app"
fi

if [[ "$RUN" == "1" ]]; then
	echo "==> Launching"
	open "$APP"
else
	echo
	echo "Next: open \"$APP\""
	echo "Then grant Screen Recording in System Settings > Privacy & Security,"
	echo "and reopen the app. Default capture shortcut: Cmd-K."
fi
