#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Drive real SDL clicks/shortcuts: record, stop, pause, browse, resume, record, quit."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
from validate import validate, jsonl

build = pathlib.Path(sys.argv[1]).resolve()
# Exercise the real GPU/display backend when requested; dummy cannot expose
# invalid GPU texture mappings during window resize or UI rendering.
environment = dict(os.environ)
if '--native' not in sys.argv[2:]:
    environment.update(SDL_VIDEODRIVER='dummy', SDL_AUDIODRIVER='dummy')
root = pathlib.Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='gamedex-shell-test-') as temp:
    temp = pathlib.Path(temp)
    rom, library, screenshots = temp / 'test.gba', temp / 'recordings', temp / 'screens'
    library.mkdir()
    bad = library / 'broken'; bad.mkdir(); (bad / 'metadata.json').write_text('{malformed')
    subprocess.run([sys.executable, str(root / 'make-test-rom.py'), str(rom)], check=True)
    run = subprocess.run([
        str(build / 'sdl/mgba'), '-C', 'gamedexShell=1', '-C', f'gamedexLibrary={library}',
        '-C', f'gamedexShellTest={screenshots}', '-C', 'skipBios=1', str(rom)],
        env=environment,
        capture_output=True, timeout=30)
    assert run.returncode == 0, run.stderr.decode()
    sessions = sorted(p for p in library.iterdir() if p.name.startswith('mgba-'))
    assert len(sessions) == 3, [p.name for p in sessions]
    previous_end = 0
    for session in sessions:
        try:
            m = validate(session)
        except AssertionError:
            print(run.stderr.decode(), file=sys.stderr)
            print((session / 'metadata.json').read_text(), file=sys.stderr)
            raise
        clock = m['mgba_capture']
        assert clock['origin_cycle'] > previous_end, 'Starting recording reset the running game'
        previous_end = clock['origin_cycle'] + clock['emulated_cycles']
        assert next(jsonl(session / 'mgba-frames.jsonl')) == {'frame_id': 0, 'native_frame': 0, 'source_cycle': 0}
    assert next(jsonl(sessions[0] / 'actions.jsonl'))['inputs']['keys'] == ['x'], 'Held input lost at recording start'
    for name in ('standby.bmp', 'recording.bmp', 'settings.bmp'):
        assert (screenshots / name).stat().st_size > 10000, name
    assert 'complete' not in (bad / 'metadata.json').read_text()
    print('PASS: UI record switch, held-input start, multiple takes without reset, focus pause, settings browsing, resume and active-recording shutdown')
