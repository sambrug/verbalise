#!/usr/bin/env python3
"""Recovery tests for the recording lifecycle.

These cover the failure that used to leave the pill stuck on "recording"
with a dead trigger key: the input stream's stop never returning because
macOS had killed the device's IO thread. They drive the real OpenWhisper
state machine with fake streams, so no microphone (and no wedged driver)
is needed.

Run with:  make test      or      .venv/bin/python3 tests/test_recovery.py
"""
import importlib.util
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
_spec = importlib.util.spec_from_file_location("owdaemon", ROOT / "daemon.py")
ow = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ow)

import numpy as np  # noqa: E402  (after the daemon import, which sets env vars)

# Never touch the user's real stats / recent-transcripts files.
ow.update_stats_and_recent = lambda text: None
ow.load_api_usage = lambda: {}

CONFIG = {
    'sample_rate': 16000, 'transcription_model': 'turbo', 'cleanup_enabled': False,
    'cleanup_quality': 'low', 'trigger_key': 'alt_r+shift_r', 'language': 'en',
    'min_duration': 0.5, 'max_duration': 300, 'release_delay': 0.0,
    'sound_enabled': False, 'overlay_enabled': False, 'vocabulary': [],
    'input_device': None, 'api_model': 'x', 'api_input_price_per_mtok': 1.0,
    'api_output_price_per_mtok': 5.0, 'api_cleanup_prompt': '', 'cleanup_prompt': '',
    'anthropic_api_key': None, 'phonetic_corrections': {},
}

results = []


def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print(f"{'PASS' if ok else 'FAIL'}  {name}{'  — ' + detail if detail else ''}")


class WedgedStream:
    """A stream whose stop/abort/close never return — the real failure mode.

    PortAudio's blocking stop waits for the audio callback to acknowledge.
    When CoreAudio has stopped running our IO proc, that never happens.
    """

    def __init__(self):
        self.abort_entered = threading.Event()

    def start(self):
        pass

    def abort(self):
        self.abort_entered.set()
        time.sleep(3600)

    def stop(self):
        time.sleep(3600)

    def close(self):
        time.sleep(3600)


class HealthyStream:
    def __init__(self):
        self.closed = False

    def start(self):
        pass

    def abort(self):
        pass

    def stop(self):
        pass

    def close(self):
        self.closed = True


def make_daemon():
    d = ow.OpenWhisper(dict(CONFIG))
    d.overlay_msgs = []
    d._overlay_send = lambda msg: d.overlay_msgs.append(msg)
    d.typed = []
    d.type_at_cursor = lambda text: d.typed.append(text)
    d.transcribe = lambda audio, model_name=None: "hello world"
    d._trigger_keys = {ow.keyboard.Key.alt_r, ow.keyboard.Key.shift_r}
    return d


def as_if_recording(d, stream, seconds=20.0, with_audio=True):
    """Put the daemon in the state start_recording would have left it in."""
    d._stream = stream
    d._recording = True
    d._key_held = True
    d._record_start_time = time.time() - seconds
    d._audio_buffer_ceiling = int(d.sample_rate * 600)
    if with_audio:
        block = np.random.default_rng(0).normal(0, 0.05, (16000, 1)).astype('float32')
        d._audio_blocks = [block for _ in range(int(seconds))]
        d._audio_total_samples = 16000 * int(seconds)
    d.overlay_msgs.append({"cmd": "show", "state": "recording"})


def release(d):
    """What on_release does, minus the keyboard event."""
    d._key_held = False
    d._processing = True


# --- The bug: release with a wedged device must still recover ---------------
d = make_daemon()
wedged = WedgedStream()
as_if_recording(d, wedged)
release(d)
t0 = time.time()
t = threading.Thread(target=d.stop_and_transcribe, daemon=True)
t.start()
t.join(timeout=30)
elapsed = time.time() - t0
check("wedged device: stop path returns", not t.is_alive(), f"{elapsed:.1f}s")
check("wedged device: teardown was attempted", wedged.abort_entered.is_set())
check("wedged device: recovers inside the teardown ceiling",
      elapsed < d._STREAM_TEARDOWN_TIMEOUT + 1.0, f"{elapsed:.1f}s")
check("wedged device: processing flag cleared", d._processing is False)
check("wedged device: pill hidden", {"cmd": "hide"} in d.overlay_msgs)
check("wedged device: captured audio still transcribed", d.typed == ["hello world"],
      f"typed={d.typed}")
check("wedged device: audio subsystem flagged", d._audio_subsystem_suspect is True)

# The whole point: no restart needed, the next dictation starts.
started = []
d.start_recording = lambda: started.append(True)
d.on_press(ow.keyboard.Key.alt_r)
d.on_press(ow.keyboard.Key.shift_r)
time.sleep(0.3)
check("after a wedge: next dictation can start", started == [True])

# --- Escape as the manual escape hatch -------------------------------------
d2 = make_daemon()
as_if_recording(d2, WedgedStream())
release(d2)
d2._stop_started_at = time.time() - 10
d2.on_press(ow.keyboard.Key.esc)
time.sleep(d2._STREAM_TEARDOWN_TIMEOUT + 1.0)
check("escape on a stalled stop: state reset", not d2._processing and not d2._recording)
check("escape on a stalled stop: pill hidden", {"cmd": "hide"} in d2.overlay_msgs)

d3 = make_daemon()
d3._processing = True
d3._stop_started_at = time.time() - 0.5   # a healthy, in-flight transcription
d3.on_press(ow.keyboard.Key.esc)
time.sleep(0.5)
check("escape during a normal transcribe: left alone", d3._processing is True)

# --- A device that starts but never delivers audio -------------------------
opened = []


def fake_open():
    s = HealthyStream()
    opened.append(s)
    return s


d4 = make_daemon()
d4._CAPTURE_HEALTH_DELAY = 0.1
d4._open_input_stream = fake_open
as_if_recording(d4, WedgedStream(), with_audio=False)
d4._audio_total_samples = 0
d4._audio_blocks = []
d4._capture_health_check()
check("dead mic: stream reopened", len(opened) == 1, f"opens={len(opened)}")
check("dead mic: recording continues", d4._recording is True)

d5 = make_daemon()
d5._CAPTURE_HEALTH_DELAY = 0.1
d5._open_input_stream = fake_open
as_if_recording(d5, HealthyStream())
before = len(opened)
d5._capture_health_check()
check("healthy mic: no reopen", len(opened) == before)

# --- A leaked max_duration timer must not cut a later dictation short ------
d6 = make_daemon()
d6._key_held = False
d6._max_duration_timer = threading.Timer(999, lambda: None)
stops = []
d6.stop_and_transcribe = lambda: stops.append(True)
d6._auto_stop()
check("leaked timer: ignored when nothing is recording", stops == [])
check("leaked timer: reference cleared", d6._max_duration_timer is None)

# --- An abandoned dictation must not paste text later ----------------------
d7 = make_daemon()
as_if_recording(d7, HealthyStream(), seconds=5.0)
release(d7)


def _transcribe_then_abandon(audio, model_name=None):
    # Escape / force_reset landing while the transcription is in flight.
    d7._dictation_seq += 1
    return "hello world"


d7.transcribe = _transcribe_then_abandon
d7.stop_and_transcribe()
check("abandoned dictation: text not typed", d7.typed == [], f"typed={d7.typed}")

# --- The normal path still works end to end -------------------------------
d8 = make_daemon()
healthy = HealthyStream()
as_if_recording(d8, healthy, seconds=5.0)
release(d8)
d8.stop_and_transcribe()
states = [m.get("s") for m in d8.overlay_msgs if m.get("cmd") == "state"]
check("normal path: transcribed and typed", d8.typed == ["hello world"])
check("normal path: stream closed", healthy.closed is True)
check("normal path: pill went to transcribing", states == ["transcribing"], f"states={states}")
check("normal path: ends hidden and ready",
      d8.overlay_msgs[-1] == {"cmd": "hide"} and d8._processing is False)
check("normal path: no false wedge flag", d8._audio_subsystem_suspect is False)

print()
failed = [r for r in results if not r[1]]
print(f"{len(results) - len(failed)}/{len(results)} passed")
sys.exit(1 if failed else 0)
