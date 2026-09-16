# Recovered GameDex 1.2.1 file format

Reference binary: GameDex macOS 1.2.1 build 3, SHA-256
`cc71a569d4650a70996b547641542f6d1673d2e24371c2ac8285e546306d38ea`.
This is an independently implemented writer, based on static examination of
serializer field names and types, not recovered application source or an official
server specification. Original disassembly lives in the parent GameDex analysis
workspace and is not redistributed in this fork.

Relevant ARM64 serializer addresses before ASLR:

| Function | Address | Contract |
| --- | --- | --- |
| `ActionsWriter.writeFrame` | `0x10006eb40` | `frame_id` UInt64, `timestamp_ms` Double, `inputs` object |
| `InputState.canonicalJSONString` | `0x10006d1d0` | `keys` string array, `mouse` object, optional nonempty `controllers` array |
| `InputEvent.canonicalJSONString` | `0x10006da7c` | `timestamp_ms`, `type`, `data` |
| `InputEventPayload.canonicalJSONString` | `0x10006dd74` | Optional payload fields, including string `key` |
| `SessionMetadata.CodingKeys.rawValue` | `0x10005a8b8` | Snake-case session fields and nested metadata |
| `VideoMetadata.init` | `0x10005b2f8` | UInt32 width, height, fps, crf; string codec/encoder; UInt64 totalFrames |
| `AudioMetadata.init` | `0x10005ba40` | enabled/saved booleans; optional sample rate, channels and format |
| `SessionStats.init` | `0x10005c140` | Event counts, unique key names, controller indices, dropped frames |

An action row (one newline-terminated object per MP4 frame):

```json
{"frame_id":0,"timestamp_ms":0,"inputs":{"keys":["x"],"mouse":{"x":0,"y":0,"buttons":{"left":false,"right":false,"middle":false}}}}
```

A transition in the raw event file:

```json
{"timestamp_ms":16.72,"type":"key_press","data":{"key":"x"}}
```

`key_release` has the same payload. The recorder omits physical keycodes, mouse
movement/click/scroll events and physical controller objects because it does not
observe those data. Empty `controllers` is omitted as in the canonical serializer.

Virtual keys express mGBA's default keyboard mapping using GameDex's naming
convention. `MacKeyMap.windowsCompatibleName` confirms the `Key.` prefix for
special keys (e.g. `Key.down` at `0x10003f3e0`, `Key.backspace` at
`0x10003f574`, and `Key.enter` at `0x10003fdb4`):

| GBA button | Virtual key |
| --- | --- |
| A / B | `x` / `z` |
| Select / Start | `Key.backspace` / `Key.enter` |
| Right / Left / Up / Down | `Key.right` / `Key.left` / `Key.up` / `Key.down` |
| R / L | `s` / `a` |

The physical key or controller button that produced an emulated button is
intentionally not reconstructed. Consumers must use this mapping, also present
in `metadata.mgba_capture.button_keys` in GBA bit order.

Metadata uses `session_id` (UUID), `game_name` (ROM header title), `start_time` and
`end_time` (UTC ISO 8601), `duration_seconds`, `upload_status`, and:

- `video`: width, height, integer fps, codec, encoder, crf, total_frames.
- `audio`: enabled, saved, sample_rate, channels, format.
- `stats`: total_key_events, total_mouse_events, total_controller_events,
  unique_keys_used, controllers_used, dropped_frames.
- `system`: os, rust_version. The latter is explicitly marked not applicable;
  this implementation is C/C++ and does not impersonate the original recorder.

`mgba_capture` is an extension containing completion/error status, clock frequency,
native frame period, native frame count, final cycle, and input interpretation.
All files are local. There is no backend registration or upload implementation.
