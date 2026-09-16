#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
set -eu
if [ "$#" -ne 1 ]; then echo "Usage: $0 ROM.gba-or-zip" >&2; exit 2; fi
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
if [ ! -f "$1" ]; then echo "ROM does not exist: $1" >&2; exit 1; fi
exec "$root/build-gamedex/sdl/mgba" -C gamedexShell=1 -C frameskip=0 -C rewindEnable=0 "$1"
