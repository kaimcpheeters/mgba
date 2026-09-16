#!/bin/sh
# Render the shared layered SVG into the Apple asset catalog.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
source="$root/doc/gamedex/icon/app-icon.svg"
assets="$root/src/platform/apple/GameDex/Assets.xcassets/AppIcon.appiconset"
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    pixels=$((size * scale))
    rsvg-convert -w "$pixels" -h "$pixels" "$source" -o "$assets/mac-$size@${scale}x.png"
  done
done
rsvg-convert -w 1024 -h 1024 "$source" | magick png:- -background '#262830' -alpha remove -alpha off "PNG24:$assets/ios-1024.png"
