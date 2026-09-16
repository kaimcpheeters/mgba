#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Native-window integration test. Does not use Accessibility or screen capture APIs."""
import json
import pathlib
import subprocess
import sys
import tempfile
from validate import validate

app = pathlib.Path(sys.argv[1]).resolve()
exe = app / 'Contents/MacOS/GameDex'
root = pathlib.Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='gamedex-apple-test-') as temp:
    temp = pathlib.Path(temp)
    rom = temp / 'original.gba'
    subprocess.run([sys.executable, str(root / 'make-test-rom.py'), str(rom)], check=True)
    result = subprocess.run([str(exe), '--rom', str(rom), '--self-test', str(temp)], capture_output=True, timeout=45)
    assert result.returncode == 0, result.stderr.decode()
    sessions = sorted((temp / 'recordings').glob('mgba-*'))
    assert len(sessions) == 2, result.stderr.decode()
    first, second = [validate(p) for p in sessions]
    assert set(first['stats']['unique_keys_used']) == set(first['mgba_capture']['button_keys']), 'Native keyboard input missed buttons'
    assert second['mgba_capture']['origin_cycle'] >= first['mgba_capture']['origin_cycle'] + first['mgba_capture']['emulated_cycles'], 'Game reset between takes'
    for name in ('recording', 'collapsed', 'expanded', 'double'):
        assert (temp / (name + '.png')).stat().st_size > 50000, 'Empty UI snapshot'
    # Standard ffmpeg tools avoid adding a Python imaging dependency. Compare the
    # compact area before and after expansion while the game is paused.
    def rgba(path, crop=None):
        cmd = ['ffmpeg', '-v', 'error', '-i', str(path)]
        if crop: cmd += ['-vf', crop]
        return subprocess.check_output(cmd + ['-f', 'rawvideo', '-pix_fmt', 'rgba', '-'])
    # The expansion icon itself changes; compare the complete handheld below its header.
    layout = json.loads((temp / 'layout.json').read_text())
    crop = f"crop={layout['width']}:{layout['height'] - 140}:0:140"
    collapsed = rgba(temp / 'collapsed.png', crop)
    expanded = rgba(temp / 'expanded.png', crop)
    # SwiftUI gradient dithering varies by up to two channel values between renders.
    assert len(collapsed) == len(expanded) and max(abs(a - b) for a, b in zip(collapsed, expanded)) <= 2, 'Expanding changed the handheld dimensions or content'
    print('PASS: all ten native keyboard mappings, stable compact layout, two GameDex captures, media decoding and shutdown finalization')
