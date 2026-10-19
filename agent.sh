#!/usr/bin/env bash
# Measure this Mac, compare it to a MacBook Neo, and apply the difference.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN="$ROOT/build/Neochalega.app/Contents/MacOS/Neochalega"
if [[ ! -x "$BIN" ]]; then
  "$ROOT/build.sh"
fi
exec "$BIN" on
