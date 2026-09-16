#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
if command -v brew >/dev/null 2>&1; then
    prefix=$(brew --prefix)
    export PKG_CONFIG_PATH="$prefix/opt/ffmpeg/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    export CMAKE_PREFIX_PATH="$prefix${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
fi
cmake -S "$root" -B "$root/build-gamedex" \
    -DBUILD_GAMEDEX=ON -DBUILD_QT=OFF -DBUILD_SDL=ON -DSDL_VERSION=2 \
    -DBUILD_GL=OFF -DBUILD_GLES2=OFF -DBUILD_GLES3=OFF \
    -DBUILD_SHARED=OFF -DBUILD_STATIC=ON -DBUILD_LTO=OFF \
    -DUSE_DISCORD_RPC=OFF -DUSE_FFMPEG=OFF "$@"
cmake --build "$root/build-gamedex" --parallel 8
