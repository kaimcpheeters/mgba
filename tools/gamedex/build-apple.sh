#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
platform=${1:-macos}
"$root/tools/gamedex/build-apple-core.sh" "$platform"
xcodegen generate --spec "$root/src/platform/apple/project.yml"
case "$platform" in
 macos) scheme=GameDexMac; destination='generic/platform=macOS' ;;
 simulator) scheme=GameDexIOS; destination='generic/platform=iOS Simulator' ;;
 ios) scheme=GameDexIOS; destination='generic/platform=iOS' ;;
esac
xcodebuild -project "$root/src/platform/apple/GameDexPocket.xcodeproj" -scheme "$scheme" \
 -configuration Debug -destination "$destination" -derivedDataPath "$root/build-apple-app-$platform" \
 CODE_SIGNING_ALLOWED=NO build
