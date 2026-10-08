#!/bin/bash
# Builds build/OnlyNote.app and build/OnlyNote.zip (what a release carries). Needs a Mac with Xcode
# or its Command Line Tools; GitHub Actions runs it, so nobody has to build anything by hand.
#
#   VERSION=0.1.7 scripts/build-app.sh
#
# The app's update runs it too, on your Mac, when GitHub hasn't built that commit yet (UNIVERSAL=0:
# just this Mac's chip, which works with only the Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0-dev}"
COMMIT="${COMMIT:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
# The branch the app's updater follows.
BRANCH="${BRANCH:-main}"
NAME=OnlyNote
APP="build/$NAME.app"

if [[ "${UNIVERSAL:-1}" == 1 ]]; then ARCHS=(--arch arm64 --arch x86_64); else ARCHS=(); fi
swift build -c release --product "$NAME" ${ARCHS[@]+"${ARCHS[@]}"}
BINDIR="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINDIR/$NAME" "$APP/Contents/MacOS/$NAME"
scripts/make-icon.sh "$APP/Contents/Resources/AppIcon.icns" || echo "warning: no app icon (it still works)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.ainigh.onlynote</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>Only Note</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>OnlyNoteCommit</key><string>$COMMIT</string>
  <key>OnlyNoteBranch</key><string>$BRANCH</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: Apple silicon only runs signed code, and this needs no developer account.
codesign --force --sign - --timestamp=none "$APP"
ditto -c -k --keepParent "$APP" "build/$NAME.zip"
echo "built $APP ($VERSION, $BRANCH, $COMMIT)"
