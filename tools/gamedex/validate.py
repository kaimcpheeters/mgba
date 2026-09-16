#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Validate GameDex file contract plus mGBA timing/media consistency, without uploading."""
import argparse
import json
import math
import pathlib
import subprocess
import wave


def jsonl(path):
    with path.open() as f:
        for line in f:
            yield json.loads(line)


def validate(directory):
    d = pathlib.Path(directory)
    m = json.loads((d / 'metadata.json').read_text())
    assert m['upload_status'] == 'pending' and m['mgba_capture']['complete']
    assert set(('session_id', 'game_name', 'start_time', 'end_time', 'duration_seconds',
                'video', 'audio', 'stats', 'system', 'upload_status')) <= m.keys()
    v = m['video']
    assert type(v['fps']) is int and v['fps'] == 60
    assert v['codec'] == 'h264' and (v['width'], v['height']) == (240, 160)
    probe = json.loads(subprocess.check_output([
        'ffprobe', '-v', 'error', '-select_streams', 'v:0', '-count_frames',
        '-show_streams', '-show_frames', '-of', 'json', str(d / 'video.mp4')]))
    stream = probe['streams'][0]
    assert stream['codec_name'] == 'h264' and stream['pix_fmt'] == 'yuv420p'
    assert stream['r_frame_rate'] == '60/1'
    assert int(stream['nb_read_frames']) == v['total_frames']
    assert math.isclose(float(stream['duration']), m['duration_seconds'], abs_tol=1e-6)
    actions = list(jsonl(d / 'actions.jsonl'))
    events = list(jsonl(d / 'events.jsonl'))
    mapping = list(jsonl(d / 'mgba-frames.jsonl'))
    assert len(actions) == len(mapping) == len(probe['frames']) == v['total_frames']
    clock_hz = m['mgba_capture']['clock_hz']
    pressed, unique, at, prev = set(), set(), 0, -1
    for e in events:
        assert e['type'] in ('key_press', 'key_release') and e['timestamp_ms'] >= prev
        assert isinstance(e['data']['key'], str)
        prev = e['timestamp_ms']
        unique.add(e['data']['key'])
    for i, (a, image, decoded) in enumerate(zip(actions, mapping, probe['frames'])):
        t = i * 1000 / 60
        assert a['frame_id'] == image['frame_id'] == i
        assert math.isclose(a['timestamp_ms'], t, abs_tol=1e-8)
        assert math.isclose(float(decoded['best_effort_timestamp_time']) * 1000, t, abs_tol=.001)
        assert image['source_cycle'] / clock_hz * 1000 <= t + 1e-8
        while at < len(events) and events[at]['timestamp_ms'] <= t + 1e-8:
            e = events[at]
            if e['type'] == 'key_press': pressed.add(e['data']['key'])
            else: pressed.remove(e['data']['key'])
            at += 1
        assert set(a['inputs']['keys']) == pressed
        assert a['inputs']['mouse'] == {'x': 0, 'y': 0, 'buttons': {'left': False, 'right': False, 'middle': False}}
    assert len(events) == m['stats']['total_key_events']
    assert set(m['stats']['unique_keys_used']) == unique
    last = -1
    for poll in jsonl(d / 'mgba-inputs.jsonl'):
        assert last <= poll['cycle'] <= m['mgba_capture']['emulated_cycles']
        assert 0 <= poll['buttons'] <= 1023
        last = poll['cycle']
    with wave.open(str(d / 'audio.wav'), 'rb') as w:
        assert (w.getframerate(), w.getnchannels(), w.getsampwidth()) == (44100, 2, 2)
        assert abs(w.getnframes() / 44100 - m['duration_seconds']) <= .002
    subprocess.run(['ffmpeg', '-v', 'error', '-i', str(d / 'video.mp4'), '-f', 'null', '-'], check=True)
    return m


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('session')
    m = validate(parser.parse_args().session)
    print(f"Valid local GameDex export: {m['video']['total_frames']} frames, {m['duration_seconds']:.3f}s")
