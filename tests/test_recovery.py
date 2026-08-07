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
ow.load_stats = lambda: {}

CONFIG = {
    'sample_rate': 16000, 'transcription_model': 'turbo',
    'trigger_key': 'alt_r+shift_r', 'language': 'en',
    'min_duration': 0.5, 'max_duration': 300, 'release_delay': 0.0,
    'sound_enabled': False, 'overlay_enabled': False, 'vocabulary': [],
    'input_device': None, 'phonetic_corrections': {},
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

# --- Clipboard paste path: never paste the user's old clipboard ------------
#
# The long-text path puts the dictation on the clipboard, sends Cmd+V, then
# restores what was there before. Two ways that used to insert the wrong text:
# a pasteboard write that silently didn't take, and restoring before the
# focused app had read the pasteboard.

class FakeClipboard:
    """Stands in for the macOS pasteboard, with a refusal mode."""

    def __init__(self, initial="PREVIOUS CLIPBOARD", refuse_writes=False):
        self.value = initial
        self.refuse_writes = refuse_writes
        self.writes = []

    def install(self):
        ow._get_clipboard_text = lambda: self.value
        ow._set_clipboard_text = self._set
        return self

    def _set(self, text):
        if self.refuse_writes:
            return False        # pasteboard server busy
        self.value = text
        self.writes.append(text)
        return True


class FakeKeyboard:
    """Captures Cmd+V instead of sending it to whatever app has focus."""

    sent = []

    def __init__(self):
        pass

    def press(self, key):
        FakeKeyboard.sent.append(('press', str(key)))

    def release(self, key):
        FakeKeyboard.sent.append(('release', str(key)))


import pynput.keyboard  # noqa: E402
pynput.keyboard.Controller = FakeKeyboard


def real_typing(d):
    """Undo make_daemon's type_at_cursor stub so the real paste path runs."""
    del d.type_at_cursor
    return d

LONG = "This is a long dictation, well over the fast-typing threshold, so it takes the clipboard path."
assert len(LONG) > 80

# A pasteboard that refuses our write must not lead to a paste at all.
d9 = real_typing(make_daemon())
clip = FakeClipboard(refuse_writes=True).install()
FakeKeyboard.sent = []
d9.type_at_cursor(LONG)
check("clipboard refused: no paste sent", FakeKeyboard.sent == [],
      f"sent={FakeKeyboard.sent}")
check("clipboard refused: user's clipboard untouched", clip.value == "PREVIOUS CLIPBOARD")

# Something overwriting the clipboard between our write and the keystroke.
d10 = real_typing(make_daemon())
d10.config['release_delay'] = 0.05
clip = FakeClipboard().install()
FakeKeyboard.sent = []
real_get = ow._get_clipboard_text


def _get_then_hijack():
    # First read is the "what was there before" read; the check just before
    # the keystroke then sees someone else's content.
    ow._get_clipboard_text = lambda: "SOMETHING ELSE COPIED"
    return "PREVIOUS CLIPBOARD"


ow._get_clipboard_text = _get_then_hijack
d10.type_at_cursor(LONG)
check("clipboard hijacked before paste: no paste sent", FakeKeyboard.sent == [],
      f"sent={FakeKeyboard.sent}")

# The happy path: paste is sent, and the old clipboard comes back afterwards.
d11 = real_typing(make_daemon())
d11.config['release_delay'] = 0.0
d11.config['clipboard_restore_delay'] = 0.2
clip = FakeClipboard().install()
FakeKeyboard.sent = []
d11.type_at_cursor(LONG)
check("normal paste: Cmd+V sent", [k for _, k in FakeKeyboard.sent if 'v' in k.lower()] != [])
check("normal paste: dictation was on the clipboard at paste time",
      clip.writes[0] == LONG, f"first write={clip.writes[:1]}")
check("normal paste: dictation still on clipboard immediately after",
      clip.value == LONG)
time.sleep(0.5)
check("normal paste: previous clipboard restored after the delay",
      clip.value == "PREVIOUS CLIPBOARD", f"value={clip.value!r}")

# A user copy during the restore window must survive.
d12 = real_typing(make_daemon())
d12.config['release_delay'] = 0.0
d12.config['clipboard_restore_delay'] = 0.3
clip = FakeClipboard().install()
FakeKeyboard.sent = []
d12.type_at_cursor(LONG)
clip.value = "USER COPIED THIS WHILE WAITING"
time.sleep(0.6)
check("user copy during restore window: not clobbered",
      clip.value == "USER COPIED THIS WHILE WAITING", f"value={clip.value!r}")

# Short text never touches the clipboard at all.
d13 = real_typing(make_daemon())
clip = FakeClipboard().install()
typed_unicode = []
d13._type_unicode = lambda t: typed_unicode.append(t)
d13.type_at_cursor("short one")
check("short text: unicode path, clipboard untouched",
      typed_unicode == ["short one"] and clip.writes == [])

ow._get_clipboard_text = real_get

# --- Streaming transcribe: ordering, failure fallback, quiet-tail skip ------

# Chunks come back in feed order even when transcription finishes out of order.
slow_first = threading.Event()


def _ordered_transcribe(audio):
    # First chunk waits until the second has been fed, proving order is
    # restored by index rather than completion time.
    if not slow_first.is_set():
        slow_first.set()
        time.sleep(0.2)
        return "one"
    return "two"


s = ow.StreamingTranscriber(_ordered_transcribe)
s.feed(np.zeros(16000, dtype='float32'))
s.feed(np.zeros(16000, dtype='float32'))
check("streaming: chunks join in feed order", s.drain() == ["one", "two"])
check("streaming: no failure flagged", s.failed is False)

# A chunk that raises must flag the streamer as failed, not crash it.
def _raising_transcribe(audio):
    raise RuntimeError("model fell over")


s2 = ow.StreamingTranscriber(_raising_transcribe)
s2.feed(np.zeros(16000, dtype='float32'))
check("streaming: failed chunk flagged", s2.drain() == [""] and s2.failed is True)

# End-to-end: a mid-recording chunk plus the leftover audio both get typed.
d14 = make_daemon()
as_if_recording(d14, HealthyStream(), seconds=5.0)
d14._streamer = ow.StreamingTranscriber(d14.transcribe)
d14._streamer.feed(np.random.default_rng(1).normal(0, 0.05, 16000).astype('float32'))
d14._streamer_last_cut = 16000  # first second already streamed
release(d14)
d14.stop_and_transcribe()
check("streaming finalize: chunk + leftover joined",
      d14.typed == ["hello world hello world"], f"typed={d14.typed}")

# A failed chunk mid-stream falls back to one single-pass transcription.
d15 = make_daemon()
as_if_recording(d15, HealthyStream(), seconds=5.0)
d15._streamer = ow.StreamingTranscriber(_raising_transcribe)
d15._streamer.feed(np.zeros(16000, dtype='float32'))
d15._streamer_last_cut = 16000
release(d15)
d15.stop_and_transcribe()
check("streaming failure: falls back to single pass, nothing dropped",
      d15.typed == ["hello world"], f"typed={d15.typed}")

# A near-silent tail after real chunks is not transcribed on its own.
d16 = make_daemon()
as_if_recording(d16, HealthyStream(), seconds=5.0)
d16._audio_blocks.append(np.zeros((16000, 1), dtype='float32'))  # silent tail
d16._audio_total_samples += 16000
d16._streamer = ow.StreamingTranscriber(d16.transcribe)
d16._streamer.feed(np.random.default_rng(2).normal(0, 0.05, 16000).astype('float32'))
d16._streamer_last_cut = 16000 * 5  # everything voiced already streamed
release(d16)
d16.stop_and_transcribe()
check("streaming: silent tail skipped, chunk still typed",
      d16.typed == ["hello world"], f"typed={d16.typed}")

# --- Idle model unload -------------------------------------------------------

d17 = make_daemon()
unloads = []
d17._unload_whisper = lambda idle: unloads.append(idle)
d17._model_loaded = True
d17.config['model_idle_unload_minutes'] = 120

d17._last_activity = time.time() - 30 * 60
check("idle unload: not before the threshold",
      d17._maybe_unload_model() is False and unloads == [])

d17._last_activity = time.time() - 121 * 60
check("idle unload: fires past the threshold",
      d17._maybe_unload_model() is True and len(unloads) == 1)

d17._model_loaded = True
d17._recording = True
check("idle unload: never during a recording",
      d17._maybe_unload_model() is False and len(unloads) == 1)
d17._recording = False

d17.config['model_idle_unload_minutes'] = 0
check("idle unload: 0 disables it",
      d17._maybe_unload_model() is False and len(unloads) == 1)

# --- Live config reload (SIGHUP path) ----------------------------------------

import tempfile  # noqa: E402

d18 = make_daemon()
with tempfile.NamedTemporaryFile('w', suffix='.yaml', delete=False) as f:
    f.write("trigger_key: shift_r\noverlay_enabled: false\n")
    reload_path = f.name
d18._config_path = reload_path
d18.reload_config()
check("config reload: trigger key applied live",
      d18._trigger_keys == {ow.KEY_MAP['shift_r']},
      f"keys={d18._trigger_keys}")
check("config reload: defaults filled in",
      d18.config['transcription_model'] == 'turbo'
      and d18.config['streaming_transcribe_enabled'] is True)

# An invalid config must be rejected wholesale, keeping the old settings.
with open(reload_path, 'w') as f:
    f.write("trigger_key: not_a_key\n")
d18.reload_config()
check("config reload: invalid config rejected, old trigger kept",
      d18._trigger_keys == {ow.KEY_MAP['shift_r']})

Path(reload_path).unlink(missing_ok=True)

print()
failed = [r for r in results if not r[1]]
print(f"{len(results) - len(failed)}/{len(results)} passed")
sys.exit(1 if failed else 0)
