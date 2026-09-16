#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Exercise the real core and encoder with an original ROM, including SDL lifecycle."""
import array
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import wave
from validate import validate, jsonl

build = pathlib.Path(sys.argv[1]).resolve()
driver = build / 'src/feature/gamedex/gamedex-capture-test'
root = pathlib.Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='mgba-gamedex-test-') as tmp:
    tmp = pathlib.Path(tmp)
    rom = tmp / 'test.gba'
    subprocess.run([sys.executable, str(root / 'make-test-rom.py'), str(rom)], check=True)
    def run(args, **kwargs):
        p = subprocess.run([str(x) for x in args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, **kwargs)
        if p.returncode:
            raise AssertionError(f'{args}: {p.returncode}\n{p.stderr.decode()}')
        return p
    for mode in ('normal', 'pause', 'long', 'audio-rate', 'all-keys', 'reset', 'load', 'disk-full'):
        run([driver, rom, tmp / mode, mode])
        metadata = json.loads((tmp / mode / 'metadata.json').read_text())
        if mode in ('reset', 'load', 'disk-full'):
            assert not metadata['mgba_capture']['complete'] and metadata['upload_status'] == 'failed'
        else:
            validate(tmp / mode)
    all_keys = json.loads((tmp / 'all-keys/metadata.json').read_text())
    assert set(all_keys['stats']['unique_keys_used']) == {'x', 'z', 's', 'a', 'Key.backspace', 'Key.enter', 'Key.right', 'Key.left', 'Key.up', 'Key.down'}
    long = json.loads((tmp / 'long/metadata.json').read_text())
    assert long['video']['total_frames'] > long['mgba_capture']['native_frames']
    for name in ('actions.jsonl', 'events.jsonl', 'mgba-inputs.jsonl', 'mgba-frames.jsonl', 'audio.wav'):
        assert (tmp / 'normal' / name).read_bytes() == (tmp / 'pause' / name).read_bytes(), name
    polls = list(jsonl(tmp / 'normal/mgba-inputs.jsonl'))
    assert polls and all(p['buttons'] & 0x30 != 0x30 for p in polls), 'Opposing directions leaked'
    events = list(jsonl(tmp / 'normal/events.jsonl'))
    assert [e['data']['key'] for e in events] == ['x', 'x', 'z', 'z', 'x', 'Key.down', 'x', 'Key.down']
    with wave.open(str(tmp / 'normal/audio.wav')) as audio:
        samples = array.array('h', audio.readframes(audio.getnframes()))
        assert max(samples) - min(samples) > 1000, 'Game audio missing'
    raw = subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(tmp / 'normal/video.mp4'), '-frames:v', '12', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'])
    pixel = raw[11 * 240 * 160 * 3 + (80 * 240 + 120) * 3:][:3]
    assert pixel[0] > 200 and pixel[1] < 35 and pixel[2] < 35, f'Wrong pixel colors: {pixel}'
    before = (tmp / 'normal/metadata.json').read_bytes()
    p = subprocess.run([str(driver), str(rom), str(tmp / 'normal')], capture_output=True)
    assert p.returncode != 0 and before == (tmp / 'normal/metadata.json').read_bytes(), 'Existing session overwritten'
    env = dict(os.environ, SDL_VIDEODRIVER='dummy', SDL_AUDIODRIVER='dummy')
    run([build / 'sdl/mgba', '-3', '-C', f'gamedexCapture={tmp / "sdl"}', '-C', 'gamedexFrames=60', '-C', 'skipBios=1', rom], env=env)
    validate(tmp / 'sdl')
    p = subprocess.run([str(build / 'sdl/mgba'), '-C', f'gamedexCapture={tmp / "sdl"}', str(rom)], env=env, capture_output=True, timeout=10)
    assert p.returncode != 0, 'SDL failed to report capture startup error'
    print('PASS: media, schema, PTS/action alignment, exact input polls, SOCD, pause, CFR duplication, audio-rate changes, reset/load rejection, disk-full, overwrite protection, SDL lifecycle and scale=3')
