# GameDex Pocket for Apple platforms

The Apple frontend shares SwiftUI views, an mGBA C bridge, playback, and native
AVFoundation recording across macOS and iOS. The core is statically linked.
Installed apps require no Homebrew libraries, SDL, Qt, or FFmpeg.

## Build and launch

Requires Xcode, CMake and XcodeGen (`brew install cmake xcodegen`). From the fork:

```sh
./tools/gamedex/build-apple.sh macos
open 'build-apple-app-macos/Build/Products/Debug/GameDex Pocket.app'
./tools/gamedex/build-apple.sh simulator
./tools/gamedex/build-apple.sh ios
```

The generated `src/platform/apple/GameDexPocket.xcodeproj` contains separate Mac
and iOS app targets using the same source files. Minimum versions are macOS 14
and iOS 17. The current build scripts target arm64 (Apple Silicon, iPhone/iPad,
and Apple Silicon Simulator). Select your development team in Xcode to sign a
physical-device build. Release signing, notarization, App Store assets and
submission are not performed by these scripts; the scripts build unsigned local
apps. ROMs, save files, and recordings are never included in the app bundle.

Open a `.gba` or `.zip` using the folder button. The app copies it into its managed
Games directory and stores its battery save beside it. A matching `.sav` next to
an imported ROM is copied when no managed save already exists. Existing saves
are not overwritten. GameDex remembers the last imported game.

## Layout and controls

- **Collapsed:** a portrait handheld with dedicated holdable D-pad, A/B, L/R,
  Start and Select controls. The Mac uses a fixed 360×780 content area (9:19.5).
- **Expanded:** the handheld keeps its size and position; a 320-point Studio panel
  opens on its right. The Mac window grows from its existing left edge.
- **iPhone:** the game image spans the entire available portrait width, preserving
  GBA's 3:2 aspect ratio. The controls fit below it within the safe area. The iOS toolbar has recording, pause, open-game and settings controls; expansion
  is Mac-only. L/R sit flush with the outer edges above the main controls, and
  the WASD hint remains visible.
- **REC light:** start/stop a recording without resetting the game. Starts off.
- **Gear:** settings and recordings, with playback that combines MP4 and WAV.
  Browsing pauses the game. Mac offers Finder access; iOS exposes Documents in
  Files and can share the video track. Raw GameDex audio and logs remain separate.

| GBA | Keyboard |
| --- | --- |
| D-pad | W / A / S / D |
| A | Return |
| B | Space |
| Start | Tab |
| Select | Shift-Tab |
| L / R | Q / E |

Keyboard input is local to the focused app. Buttons remain held until released;
touch and keyboard input can coexist. Focus loss clears held controls and pauses
the emulator. Moving iOS into the background also finalizes an active recording.

## Recording and privacy

There are **no Accessibility, Screen Recording, or microphone permissions**.
Frames come from an owned mGBA pixel buffer, audio comes from its audio buffer,
and input polls come from the core callback. AVFoundation encodes these supplied
buffers; it does not capture the screen or microphone. SwiftUI renders native text
and controls; only the 240×160 game image uses nearest-neighbor scaling.

The Apple writer produces the same five GameDex files and two cycle sidecars as
the SDL exporter; use `tools/gamedex/validate.py` on either. It uses Apple's H.264
encoder at an average 2 Mbps instead of x264 CRF: `encoder` is `avfoundation`, the
legacy integer `crf` is 0 (unused), and `mgba_capture.rate_control` identifies the
actual mode. Video is CFR 60 Hz, audio is stereo 44.1 kHz signed 16-bit WAV, and
all action/event times derive from the emulation clock. Virtual capture key names
remain GameDex's established vocabulary even though the physical mappings changed.

The portable core now maintains its 64-bit clock in non-debugger builds too.
JSON and media are validated locally; remote GameDex ingestion remains untested.
There is no upload client. Incomplete/error sessions never become `pending`.

## Verify

```sh
python3 tools/gamedex/apple-test.py \
 'build-apple-app-macos/Build/Products/Debug/GameDex Pocket.app'
```

This opens a native window, sends all ten mappings through the app's local event
handler, records two takes without reset, validates every exported file, and
compares the handheld pixels before/after expansion. It uses an original test ROM.
No Accessibility or screen capture permissions are used by the test: snapshots
are rendered from the app's own SwiftUI views. The iOS Simulator app also accepts
`--rom /path/in/container/game.gba --capture-test` for a short native recording.
