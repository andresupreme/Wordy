#!/bin/bash
# Builds a double-clickable Wordy.app in ./build
# Needs a Mac with Xcode or the Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Wordy.app"

# UNIVERSAL=1 ./build_app.sh builds for Apple Silicon and Intel Macs.
# (Needs full Xcode installed, not just the Command Line Tools.)
BUILD_FLAGS=(-c release)
if [ "${UNIVERSAL:-0}" = "1" ]; then
  BUILD_FLAGS+=(--arch arm64 --arch x86_64)
fi

echo "→ Building (release)…"
swift build "${BUILD_FLAGS[@]}"
BIN="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"

echo "→ Creating app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Wordy" "$APP/Contents/MacOS/Wordy"
cp Packaging/Info.plist "$APP/Contents/Info.plist"

echo "→ Making the icon…"
if [ ! -d Packaging/AppIcon.iconset ]; then
  echo "   (iconset missing; regenerating with Packaging/make_icon.swift)"
  swift Packaging/make_icon.swift
fi
iconutil -c icns Packaging/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

printf 'APPL????' > "$APP/Contents/PkgInfo"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "→ Signing (ad-hoc, for this Mac)…"
  codesign --force --deep --sign - "$APP"
else
  echo "→ Signing with $SIGN_IDENTITY…"
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi

echo
echo "Done: $(pwd)/$APP"
echo "Drag it into your Applications folder."
open build
