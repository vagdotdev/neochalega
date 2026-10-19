#!/usr/bin/env bash
# Build Neochalega.app. Pass --install to copy it to ~/Applications.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/build/Neochalega.app"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
swiftc -O -swift-version 5 -parse-as-library \
  -framework AppKit -framework SwiftUI -framework QuartzCore \
  -o "$OUT/Contents/MacOS/Neochalega" \
  "$ROOT"/Sources/*.swift
cp "$ROOT/Info.plist" "$OUT/Contents/Info.plist"
codesign --force --sign - "$OUT" >/dev/null
echo "built $OUT"
if [[ "${1:-}" == "--install" ]]; then
  rm -rf "$HOME/Applications/Neochalega.app"
  mkdir -p "$HOME/Applications"
  cp -R "$OUT" "$HOME/Applications/Neochalega.app"
  echo "installed $HOME/Applications/Neochalega.app"
fi
