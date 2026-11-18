#!/usr/bin/env bash
# Writes Android launcher icons (mipmap-*/ic_launcher.png) from assets/brand/icon.png.
# Requires only ffmpeg. Run from anywhere: tools/make_icons.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/assets/brand/icon.png"
RES="$ROOT/android/app/src/main/res"

command -v ffmpeg >/dev/null || { echo "ffmpeg is required" >&2; exit 1; }
[ -f "$SRC" ] || { echo "missing source icon: $SRC" >&2; exit 1; }

# density:size pairs (legacy launcher sizes, 48dp at each density)
for entry in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
  density="${entry%%:*}"
  px="${entry##*:}"
  out="$RES/mipmap-$density/ic_launcher.png"
  mkdir -p "$(dirname "$out")"
  ffmpeg -v error -y -i "$SRC" -vf "scale=$px:$px:flags=lanczos" -frames:v 1 "$out"
  echo "wrote ${out#"$ROOT"/} (${px}px)"
done
