#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
set -eu
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Usage: $0 ROM.gba [NEW_SESSION_DIRECTORY]" >&2
    exit 2
fi
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
binary="$root/build-gamedex/sdl/mgba"
if [ ! -x "$binary" ]; then
    echo "Build first: $root/tools/gamedex/build.sh" >&2
    exit 1
fi
if [ ! -f "$1" ]; then echo "ROM does not exist: $1" >&2; exit 1; fi
if [ "$#" -eq 2 ]; then
    session=$2
else
    parent="$HOME/Documents/GameDex Recordings"
    mkdir -p "$parent"
    session="$parent/mgba-$(date +%Y%m%d-%H%M%S)-$$"
fi
printf 'Recording to: %s\nClose the emulator window to finish and save the session.\n' "$session"
exec "$binary" -3 -C "gamedexCapture=$session" -C frameskip=0 -C rewindEnable=0 "$1"
