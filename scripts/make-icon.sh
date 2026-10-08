#!/bin/bash
# Draws the app's icon (a sheet of paper with a few lines on it) into an .icns:
#   scripts/make-icon.sh build/AppIcon.icns
set -euo pipefail
out="$1"
here="$(cd "$(dirname "$0")" && pwd)"
set_dir="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$set_dir"
swift "$here/icon.swift" "$set_dir"
iconutil -c icns "$set_dir" -o "$out"
