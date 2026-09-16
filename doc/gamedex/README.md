# Native GBA capture with GameDex exports

Upstream base: `mgba-emu/mgba` master at
`a1020b0e72e90d56d4779efcdf776aa9c1450fe1` (retrieved 2026-09-16).

This fork records the GBA framebuffer, emulated audio, and buttons actually sampled
by the game. The SDL frontend still displays and plays that same emulation. No
screen recorder, global keyboard hook, microphone, account, or upload is involved.

## Build and record

On macOS, install `cmake`, `pkgconf`, `sdl2`, and `ffmpeg` with Homebrew. FFmpeg must
include the `libx264` encoder. On Linux install the corresponding development
packages, a C++17 compiler, and FFmpeg 5 or newer.

```sh
./tools/gamedex/build.sh
./tools/gamedex/record.sh /path/to/game.gba
```

The launcher creates a session under `~/Documents/GameDex Recordings`. Optionally
pass a **new** session directory as the second argument; its parent must exist.
The recorder refuses to overwrite any existing directory. Close the emulator
window to finalize the MP4 and mark the session ready. Force-killing the process
leaves an incomplete session, which must not be uploaded.

Default controls: arrows, X = A, Z = B, A = L, S = R, Enter = Start,
Backspace = Select. Controllers and remapped keys work through normal mGBA input
mapping. Command/Ctrl-P pauses. Pausing does not advance recording time;
fast-forward changes wall-clock playback speed, not captured timestamps.

Direct CLI equivalent, and an optional limit measured in **native** frames:

```sh
build-gamedex/sdl/mgba -3 -C gamedexCapture=/path/to/new-session -C frameskip=0 game.gba
build-gamedex/sdl/mgba -C gamedexCapture=/path/to/test-session -C gamedexFrames=600 game.gba
python3 tools/gamedex/validate.py /path/to/new-session
```

`BUILD_GAMEDEX=ON` enables this feature. It has its own FFmpeg linkage and does not
require the upstream Qt recorder or `USE_FFMPEG`. Use a full rebuild: this fork
extends the source-level core callback structure; do not mix its headers with an
upstream prebuilt libmgba.

## Export contract

The five legacy files follow the serializers and upload allowlist recovered from
**GameDex macOS 1.2.1, build 3**. See [format details](format.md) for evidence and
semantics. The two `mgba-*` files preserve information the legacy format cannot
represent. They are not in the GameDex uploader's allowlist.

| File | Contents |
| --- | --- |
| `video.mp4` | H.264, 240×160, yuv420p, CRF 18, exactly 60 FPS |
| `audio.wav` | Game audio, PCM signed 16-bit stereo, 44,100 Hz |
| `actions.jsonl` | One `frame_id`, `timestamp_ms`, and `inputs` object per encoded frame |
| `events.jsonl` | Game-button press/release transitions using virtual keyboard names |
| `metadata.json` | GameDex session, video/audio, statistics, system and upload fields |
| `mgba-inputs.jsonl` | Every KEYINPUT poll: exact CPU cycle, native frame index, final active-high button mask |
| `mgba-frames.jsonl` | Each encoded frame's source native frame index and completion cycle |

Capture is synchronous and bounded in memory. If encoding or disk I/O cannot keep
up, emulation slows rather than dropping capture frames. FFmpeg gets a copy of the
native pixels before display scaling. It never asks the emulator to render again.

GameDex's `video.fps` is an unsigned integer. GBA's native rate is
16,777,216 / 280,896 ≈ 59.7275 Hz, so this exporter samples the **last completed**
frame at 60 Hz. Occasional repeated images are intentional. The initial image is
black until the first frame completes. The frame sidecar identifies it as
`native_frame: -1`; there is no claim that it was rendered by the game.

Both JSON time and video PTS start at capture's emulation cycle zero. Action rows
contain the sampled input state at that exact PTS, never a future input state.
Full input polls retain changes within a video frame. Native frames are numbered
by completion order; a poll's native frame is the next frame to complete. Audio
is resampled from the core stream, including sample-rate changes. At shutdown the
last CFR interval may receive less than one frame of silence padding.

## Scope and limits

- GBA and the SDL frontend are supported. Qt UI capture controls and GB/GBC
  recording are not implemented.
- Sessions start immediately after reset. Rewind is disabled. A reset or successful
  save-state load during capture marks the session failed and terminates the SDL
  run rather than silently stitching incompatible timelines. Start a new session
  for another timeline. Starting from a state/debugger is rejected.
- Mouse coordinates/buttons are neutral placeholders. `inputs.keys` represents
  **virtual game controls**, not evidence of physical keyboard activity. Controller
  inputs become the same virtual controls; no physical-controller identity is saved.
- Existing JSON readers can consume the legacy fields. Local validation exercises
  their recovered shapes, media decoding, counts, timing and statistics. The
  proprietary GameDex app and remote service have not been used to import/upload
  these sessions. Server acceptance and training-label expectations remain
  unverified; file compatibility does not establish those contracts.
- Metadata stays `upload_status: failed` and `mgba_capture.complete: false` until
  all writes/encoder finalization succeed. An interrupted process cannot advertise
  a complete session. Errors return a nonzero exit code. WAV sessions stop with an
  error before their 4 GiB container limit; split very long recordings.
- The current build uses FFmpeg/libx264 under their own licenses in addition to
  mGBA's MPL-2.0. Keep upstream license notices when redistributing a build.

## Tests

```sh
python3 tools/gamedex/test.py build-gamedex
```

Tests generate an original 1 KiB GBA ROM (`test-rom.s`), with a solid framebuffer,
button polls and a PSG tone. No commercial game or external BIOS is required.
The tests run the actual emulator and encoder, decode the media, validate JSON,
compare paused/unpaused output, test opposing-direction filtering, CFR duplicates,
audio-rate changes, reset/load handling, disk-write failure, overwrite protection,
and the SDL startup/shutdown path at 3× window scale.
