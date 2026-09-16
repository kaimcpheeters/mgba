#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
platform=${1:-macos}
case "$platform" in
 macos) system=Darwin; sdk=macosx; deployment=14.0 ;;
 simulator) system=iOS; sdk=iphonesimulator; deployment=17.0 ;;
 ios) system=iOS; sdk=iphoneos; deployment=17.0 ;;
 *) echo 'Usage: build-apple-core.sh macos|simulator|ios' >&2; exit 2 ;;
esac
cmake -S "$root" -B "$root/build-apple-$platform" \
 -DCMAKE_SYSTEM_NAME="$system" -DCMAKE_OSX_SYSROOT="$(xcrun --sdk "$sdk" --show-sdk-path)" \
 -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment" \
 -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
 -DBUILD_GAMEDEX_APPLE=ON -DBUILD_GAMEDEX=OFF -DBUILD_STATIC=ON -DBUILD_SHARED=OFF \
 -DBUILD_QT=OFF -DBUILD_SDL=OFF -DBUILD_GL=OFF -DBUILD_GLES2=OFF -DBUILD_GLES3=OFF \
 -DENABLE_DEBUGGERS=OFF -DENABLE_GDB_STUB=OFF -DENABLE_SCRIPTING=OFF -DM_CORE_GB=OFF \
 -DUSE_FFMPEG=OFF -DUSE_PNG=OFF -DUSE_LIBZIP=OFF -DUSE_MINIZIP=OFF -DUSE_ZLIB=ON \
 -DUSE_SQLITE3=OFF -DUSE_ELF=OFF -DUSE_LUA=OFF -DUSE_JSON_C=OFF -DUSE_FREETYPE=OFF \
 -DUSE_LZMA=OFF -DUSE_DISCORD_RPC=OFF -DUSE_EDITLINE=OFF -DBUILD_LTO=OFF
cmake --build "$root/build-apple-$platform" --parallel 8
