#!/usr/bin/env python3
"""
Open Whisper — SuperWhisper-like voice dictation for macOS.
Hold a trigger key to record, release to transcribe, text appears at cursor.
Runs entirely on-device using MLX Whisper.

Usage:
    python daemon.py                      # Uses config.yaml in same directory
    python daemon.py --config /path/to/config.yaml
"""
import os
os.environ["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"

# Point stdlib SSL at certifi's CA bundle.
#
# py2app's __boot__.py sets `SSL_CERT_FILE=<resources>/openssl.ca/no-such-file`
# at startup — a deliberately bogus path meant to force libs to fall back to
# certifi via their own logic. But httpx (used by huggingface_hub when
# mlx_whisper resolves a model) reads SSL_CERT_FILE *first* and crashes with
# `FileNotFoundError: [Errno 2] No such file or directory` on the fake path.
#
# We must assign directly (not `setdefault`) so the bogus value gets
# overridden. Both env vars also propagate to subprocesses we spawn.
try:
    import certifi as _certifi
    _ca_bundle = _certifi.where()
    os.environ["SSL_CERT_FILE"] = _ca_bundle
    os.environ["REQUESTS_CA_BUNDLE"] = _ca_bundle
except Exception:
    pass

import sys
import time
import json
import signal
import subprocess
import threading
import traceback
import argparse
import queue
import re
from pathlib import Path
import numpy as np
import sounddevice as sd
import yaml

import paths
from pynput import keyboard

# --- Whisper model registry ---
MLX_MODELS = {
    'tiny':            'mlx-community/whisper-tiny',
    'base':            'mlx-community/whisper-base-mlx',
    'small':           'mlx-community/whisper-small-mlx',
    'distil-medium':   'mlx-community/distil-whisper-medium.en',
    'medium':          'mlx-community/whisper-medium-mlx',
    'distil-large':    'mlx-community/distil-whisper-large-v3',
    'turbo':           'mlx-community/whisper-large-v3-turbo',
    'large':           'mlx-community/whisper-large-v3-mlx',
}

# --- Silence / hallucination filtering ---
SILENCE_RMS_THRESHOLD = 0.002

HALLUCINATION_PHRASES = {
    "thank you", "thank you.", "thanks for watching",
    "thanks for watching.", "subscribe", "like and subscribe",
    "please subscribe", "bye", "bye.", "you", "you.",
}

# Whisper learned these from YouTube/subtitle training data: when it hits
# silence at the end of audio it fills with "outro" phrases, and uses "..."
# the way subtitles do for hesitations / unclear audio. Strip them from the
# tail of any transcript before typing.
TRAILING_HALLUCINATION_PATTERNS = [
    re.compile(r"\s*\bthanks for watching\b[\.\,\!\?]*\s*$", re.IGNORECASE),
    re.compile(r"\s*\bthank you\b[\.\,\!\?]*\s*$", re.IGNORECASE),
    re.compile(r"\s*\bthanks\b[\.\,\!\?]*\s*$", re.IGNORECASE),
    re.compile(r"\s*\b(please |like and )?subscribe\b[\.\,\!\?]*\s*$", re.IGNORECASE),
    re.compile(r"\s*\bbye(\s+for now)?\b[\.\,\!\?]*\s*$", re.IGNORECASE),
    re.compile(r"\s*\bsee you (next time|in the next video)\b[\.\,\!\?]*\s*$", re.IGNORECASE),
    # 3+ consecutive ASCII dots at the end (an ellipsis hallucination —
    # can't be a normal sentence-ending period).
    re.compile(r"\s*\.{3,}\s*$"),
    # Trailing unicode horizontal ellipsis (any count).
    re.compile(r"\s*…+\s*$"),
    # Multiple whitespace-separated dot/ellipsis groups at the end. Catches
    # ". . .", "... ... ...", " . … .", and "Hello there. ..." while leaving
    # the period of a real sentence intact (because the regex requires
    # whitespace before the run starts, so a sentence-final period attached
    # to a word is never consumed).
    re.compile(r"(?:\s+[\.…]+){2,}\s*$"),
]

PUNCTUATION_ONLY_RE = re.compile(r"^[\s\.\,\!\?…]*$")


def looks_like_repetition_loop(text):
    """Detect Whisper's stuck-token repetition bug.

    The model occasionally falls into a decoding loop and emits the same
    word dozens or hundreds of times ("Region Region Region ..."). Detect
    via two signals:
      - 8+ identical words in a row (no natural speech does this)
      - 15+ words total where the most common word is >50% of them
    """
    if not text:
        return False
    words = text.lower().split()
    if len(words) < 8:
        return False
    longest_run = 1
    current_run = 1
    for i in range(1, len(words)):
        if words[i] == words[i - 1]:
            current_run += 1
            if current_run > longest_run:
                longest_run = current_run
        else:
            current_run = 1
    if longest_run >= 8:
        return True
    counts = {}
    for w in words:
        counts[w] = counts.get(w, 0) + 1
    most_common_count = max(counts.values())
    if len(words) >= 15 and most_common_count / len(words) > 0.5:
        return True
    return False


def clean_hallucinations(text):
    """Strip trailing hallucination phrases and ellipses runs, and drop the
    text entirely if it looks like a repetition-loop hallucination.

    Returns '' if the cleaned text is empty, only punctuation, or a
    repetition loop — caller should treat as no transcription.
    """
    if not text:
        return ""
    if looks_like_repetition_loop(text):
        return ""
    cleaned = text
    changed = True
    # Loop because Whisper sometimes stacks them, e.g. "... thank you. ..."
    while changed:
        changed = False
        for pattern in TRAILING_HALLUCINATION_PATTERNS:
            new = pattern.sub("", cleaned)
            if new != cleaned:
                cleaned = new
                changed = True
    cleaned = cleaned.strip()
    if PUNCTUATION_ONLY_RE.match(cleaned):
        return ""
    return cleaned

# --- Key name mapping ---
KEY_MAP = {
    'shift_r': keyboard.Key.shift_r,
    'shift_l': keyboard.Key.shift_l,
    'ctrl_r':  keyboard.Key.ctrl_r,
    'ctrl_l':  keyboard.Key.ctrl_l,
    'alt_r':   keyboard.Key.alt_r,
    'alt_l':   keyboard.Key.alt_l,
    'cmd_r':   keyboard.Key.cmd_r,
}

# Quartz modifier flag bits (kCGEventFlagMask*). Left/right share a bit, so
# the watchdog can't distinguish shift_l from shift_r — that's fine; it
# only fires when pynput has already lost the key state anyway.
_MODIFIER_FLAG_MASKS = {
    keyboard.Key.shift_l: 0x00020000,
    keyboard.Key.shift_r: 0x00020000,
    keyboard.Key.ctrl_l:  0x00040000,
    keyboard.Key.ctrl_r:  0x00040000,
    keyboard.Key.alt_l:   0x00080000,
    keyboard.Key.alt_r:   0x00080000,
    keyboard.Key.cmd_r:   0x00100000,
}


def log(msg):
    """Print a timestamped log message to stderr."""
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", file=sys.stderr, flush=True)


def emit_event(event, **payload):
    """Emit structured runtime events for the menu bar process."""
    try:
        print(json.dumps({"event": event, **payload}), file=sys.stdout, flush=True)
    except Exception:
        # Event emission must never impact dictation flow.
        pass


def play_sound(name):
    """Play a macOS system sound non-blocking."""
    sounds = {
        'start': '/System/Library/Sounds/Tink.aiff',
        'done':  '/System/Library/Sounds/Pop.aiff',
    }
    path = sounds.get(name)
    if path:
        subprocess.Popen(
            ['afplay', path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def _get_clipboard_text():
    """Read clipboard text, preferring native APIs over shell tools."""
    try:
        from AppKit import NSPasteboard, NSPasteboardTypeString
        pb = NSPasteboard.generalPasteboard()
        return pb.stringForType_(NSPasteboardTypeString) or ""
    except Exception:
        try:
            result = subprocess.run(['pbpaste'], capture_output=True, text=True, check=False)
            return result.stdout
        except Exception:
            return ""


def _set_clipboard_text(text):
    """Write clipboard text, verifying the write actually took.

    NSPasteboard.setString_forType_ returns False (without raising) if the
    pasteboard server is busy — e.g. just after another app or a Finder
    right-click+Copy touched it. If we don't check the return value, we
    silently leave the clipboard with whatever was previously there, which
    means Cmd+V then pastes the wrong content. Read back to verify; fall
    back to pbcopy if the native write didn't stick.

    Returns True if the clipboard now holds `text`.
    """
    try:
        from AppKit import NSPasteboard, NSPasteboardTypeString
        pb = NSPasteboard.generalPasteboard()
        pb.clearContents()
        ok = pb.setString_forType_(text, NSPasteboardTypeString)
        if ok:
            written = pb.stringForType_(NSPasteboardTypeString) or ""
            if written == text:
                return True
        # Native write didn't take — fall through to pbcopy.
    except Exception:
        pass
    try:
        subprocess.run(['pbcopy'], input=text.encode('utf-8'), check=False, timeout=2)
    except (OSError, subprocess.TimeoutExpired) as e:
        log(f"Clipboard write failed: {e}")
        return False
    # pbcopy exits 0 even when the pasteboard server refused the write, so
    # confirm by reading back rather than trusting the exit status.
    return _get_clipboard_text() == text


def _set_clipboard_text_verified(text, attempts=3, gap=0.08):
    """Put `text` on the clipboard, retrying a busy pasteboard server.

    Returns True only when the clipboard is confirmed to hold `text`. The
    caller must not send Cmd+V otherwise: the clipboard would still hold the
    user's previous content and the paste would insert that instead of the
    dictation.
    """
    for attempt in range(1, attempts + 1):
        if _set_clipboard_text(text):
            if attempt > 1:
                log(f"  Clipboard write took {attempt} attempts")
            return True
        time.sleep(gap)
    return False


def trim_silence(audio, sample_rate):
    """Trim leading/trailing silence using RMS hysteresis with padding."""
    if audio.size == 0:
        return audio, 0

    frame_len = max(int(sample_rate * 0.020), 1)  # 20ms
    hop = max(int(sample_rate * 0.010), 1)        # 10ms
    if audio.size < frame_len * 2:
        return audio, 0

    frame_starts = np.arange(0, audio.size - frame_len + 1, hop)
    if frame_starts.size == 0:
        return audio, 0

    rms_values = np.array([
        np.sqrt(np.mean(audio[s:s + frame_len] ** 2))
        for s in frame_starts
    ])

    enter_threshold = 0.006
    exit_threshold = 0.004
    min_quiet_frames = max(int(0.120 / 0.010), 1)  # 120ms

    in_speech = False
    quiet_frames = 0
    speech_start = None
    speech_end = None

    for i, rms in enumerate(rms_values):
        if not in_speech:
            if rms >= enter_threshold:
                in_speech = True
                quiet_frames = 0
                if speech_start is None:
                    speech_start = i
                speech_end = i
        else:
            if rms < exit_threshold:
                quiet_frames += 1
                if quiet_frames >= min_quiet_frames:
                    in_speech = False
                    quiet_frames = 0
            else:
                quiet_frames = 0
                speech_end = i

    if in_speech:
        speech_end = len(rms_values) - 1

    if speech_start is None or speech_end is None or speech_end < speech_start:
        return audio, 0

    start_pad = int(sample_rate * 0.120)
    end_pad = int(sample_rate * 0.200)
    start_sample = max(int(frame_starts[speech_start]) - start_pad, 0)
    end_sample = min(int(frame_starts[speech_end] + frame_len) + end_pad, audio.size)

    trimmed = audio[start_sample:end_sample]
    saved_samples = audio.size - trimmed.size

    # Safety guards
    if trimmed.size < int(sample_rate * 0.350):
        return audio, 0
    if saved_samples < int(sample_rate * 0.080):
        return audio, 0

    return trimmed, saved_samples


def silence_gap_index(audio, sample_rate, start_index):
    """Find the first sufficiently long low-energy gap in audio[start_index:].

    Returns the sample index where the next chunk should start (just after
    the silence), or None if no gap is found in the available audio.

    Tuned conservatively: a brief pause for breath or thought (200-300ms)
    should NOT trigger a cut, only a clear sentence boundary. A 400ms
    silence after at least 2s of speech is the bar.
    """
    if audio.size <= start_index:
        return None
    frame_len = max(int(sample_rate * 0.020), 1)   # 20ms frame
    hop = max(int(sample_rate * 0.010), 1)         # 10ms hop
    exit_threshold = 0.005
    min_quiet_hops = max(int(0.400 / 0.010), 1)    # 400ms of silence
    min_speech_hops = max(int(2.000 / 0.010), 1)   # require 2s speech first

    saw_speech_hops = 0
    quiet_hops = 0
    quiet_start = None
    i = start_index
    while i + frame_len <= audio.size:
        rms = float(np.sqrt(np.mean(audio[i:i + frame_len] ** 2)))
        if rms < exit_threshold:
            if quiet_start is None:
                quiet_start = i
            quiet_hops += 1
            if saw_speech_hops >= min_speech_hops and quiet_hops >= min_quiet_hops:
                # Cut after the silence so the previous chunk keeps trailing
                # silence (Whisper expects it) and the next chunk starts fresh.
                return quiet_start + min_quiet_hops * hop
        else:
            saw_speech_hops += 1
            quiet_start = None
            quiet_hops = 0
        i += hop
    return None


class StreamingTranscriber:
    """Transcribes audio chunks on a background thread as they're fed in.

    Each `feed(audio)` call atomically assigns a monotonic index, so concurrent
    feeds from multiple threads (the watcher and the main thread on release)
    don't collide. `drain()` blocks until all enqueued chunks are processed
    and returns the ordered list of result strings.
    """
    def __init__(self, transcribe_callable):
        self._transcribe = transcribe_callable
        self._queue = queue.Queue()
        self._results = {}
        self._stop_sentinel = object()
        self._next_index = 0
        self._index_lock = threading.Lock()
        self._chunk_count = 0
        # Set when any chunk raised during transcription. The finalize path
        # falls back to a single-pass transcription of the whole recording
        # rather than silently dropping the failed chunk's sentence.
        self.failed = False
        self._thread = threading.Thread(target=self._worker, daemon=True)
        self._thread.start()

    def _worker(self):
        while True:
            item = self._queue.get()
            try:
                if item is self._stop_sentinel:
                    return
                index, audio = item
                try:
                    text = self._transcribe(audio)
                except Exception as e:
                    log(f"Streaming chunk {index} transcribe failed: {e}")
                    self.failed = True
                    text = ""
                self._results[index] = text
            finally:
                self._queue.task_done()

    def feed(self, audio):
        """Enqueue a chunk for transcription. Returns the assigned index."""
        with self._index_lock:
            index = self._next_index
            self._next_index += 1
            self._chunk_count += 1
        self._queue.put((index, audio))
        return index

    @property
    def chunk_count(self):
        return self._chunk_count

    def drain(self):
        self._queue.join()
        self._queue.put(self._stop_sentinel)
        self._thread.join()
        return [self._results[i] for i in sorted(self._results.keys())]


def validate_config(config):
    """Validate config values and return (errors, warnings)."""
    errors = []
    warnings = []

    if config['transcription_model'] not in MLX_MODELS:
        errors.append(
            f"transcription_model '{config['transcription_model']}' invalid. "
            f"Valid: {', '.join(MLX_MODELS.keys())}"
        )

    trigger_parts = config['trigger_key'].split('+')
    invalid_parts = [p for p in trigger_parts if p not in KEY_MAP]
    if invalid_parts:
        errors.append(
            f"trigger_key '{config['trigger_key']}' contains invalid key(s): {', '.join(invalid_parts)}. "
            f"Valid keys: {', '.join(KEY_MAP.keys())}"
        )

    if not isinstance(config['min_duration'], (int, float)) or config['min_duration'] < 0:
        errors.append(f"min_duration must be a positive number, got {config['min_duration']}")

    if not isinstance(config['sample_rate'], int) or config['sample_rate'] <= 0:
        errors.append(f"sample_rate must be a positive integer, got {config['sample_rate']}")

    return errors, warnings


def _apply_phonetic_corrections(text, corrections):
    """Whole-word, case-insensitive replacement of misheard terms.

    `corrections` is a dict of {misheard: correct}. The replacement is
    written verbatim, so the user controls the final casing (e.g. "FNOL").
    """
    if not text or not corrections:
        return text
    for misheard, correct in corrections.items():
        if not misheard or not isinstance(misheard, str):
            continue
        pattern = r'\b' + re.escape(misheard) + r'\b'
        text = re.sub(pattern, str(correct), text, flags=re.IGNORECASE)
    return text


def _resolve_overlay_style(cfg):
    """Normalise overlay config to one of 'off' / 'solid' / 'translucent'.

    Newer configs carry `overlay_style` directly; older ones used the pair
    `overlay_enabled` + `overlay_translucent`, which map across here.
    """
    style = cfg.get('overlay_style')
    if style in ('off', 'solid', 'translucent'):
        return style
    if 'overlay_enabled' in cfg or 'overlay_translucent' in cfg:
        if not cfg.get('overlay_enabled', True):
            return 'off'
        return 'translucent' if cfg.get('overlay_translucent', True) else 'solid'
    return 'translucent'


def load_config(config_path):
    with open(config_path) as f:
        cfg = yaml.safe_load(f) or {}
    advanced_cfg = cfg.get('advanced', {})
    if not isinstance(advanced_cfg, dict):
        advanced_cfg = {}
    return {
        'transcription_model': cfg.get('transcription_model', 'turbo'),
        'trigger_key':         cfg.get('trigger_key', 'shift_r'),
        'language':            cfg.get('language', 'en'),
        'min_duration':        cfg.get('min_duration', 0.5),
        'release_delay':       cfg.get('release_delay', 0.05),
        'sample_rate':         cfg.get('sample_rate', 16000),
        'max_duration':            cfg.get('max_duration', 300),
        'sound_enabled':           cfg.get('sound_enabled', False),
        'overlay_style':           _resolve_overlay_style(cfg),
        'trim_silence_enabled':    advanced_cfg.get('trim_silence_enabled', cfg.get('trim_silence_enabled', True)),
        'fast_typing_enabled':     advanced_cfg.get('fast_typing_enabled', True),
        'fast_typing_max_chars':   advanced_cfg.get('fast_typing_max_chars', 80),
        'clipboard_restore_delay': advanced_cfg.get('clipboard_restore_delay', 1.5),
        'streaming_transcribe_enabled': advanced_cfg.get('streaming_transcribe_enabled', True),
        'model_idle_unload_minutes': advanced_cfg.get('model_idle_unload_minutes', 120),
        'vocabulary':              cfg.get('vocabulary', []) or [],
        'phonetic_corrections':    cfg.get('phonetic_corrections', {}) or {},
        'input_device':            cfg.get('input_device', None),
    }


# Lifetime word/recording counters. Keeps its historical filename so
# existing stats survive the removal of API usage tracking.
STATS_FILE = paths.state_dir() / 'api-usage.json'


def load_stats():
    """Load lifetime dictation stats (total words / recordings)."""
    try:
        with open(STATS_FILE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {'total_words': 0, 'total_recordings': 0}


def save_stats(stats):
    """Save lifetime dictation stats."""
    with open(STATS_FILE, 'w') as f:
        json.dump(stats, f)


RECENT_TRANSCRIPTS_FILE = paths.state_dir() / 'recent-transcripts.json'
RECENT_TRANSCRIPTS_LIMIT = 10


def load_recent_transcripts():
    try:
        with open(RECENT_TRANSCRIPTS_FILE) as f:
            data = json.load(f)
            if isinstance(data, list):
                return data
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    return []


def update_stats_and_recent(text):
    """Increment word/recording counters and prepend to the recent-transcripts list."""
    if not text or not text.strip():
        return
    stats = load_stats()
    stats['total_words'] = stats.get('total_words', 0) + len(text.split())
    stats['total_recordings'] = stats.get('total_recordings', 0) + 1
    save_stats(stats)

    recent = load_recent_transcripts()
    entry = {'text': text, 'ts': time.strftime('%Y-%m-%dT%H:%M:%S')}
    recent.insert(0, entry)
    recent = recent[:RECENT_TRANSCRIPTS_LIMIT]
    try:
        with open(RECENT_TRANSCRIPTS_FILE, 'w') as f:
            json.dump(recent, f)
    except OSError:
        pass


class OpenWhisper:
    def __init__(self, config, config_path=None):
        self.config = config
        self._config_path = config_path
        self.sample_rate = config['sample_rate']

        # Parse trigger — single key or combo (e.g. 'alt_r+shift_r')
        trigger_parts = config['trigger_key'].split('+')
        self._trigger_keys = {KEY_MAP[p] for p in trigger_parts}
        self._combo_held = set()

        self._recording = False
        self._key_held = False
        self._processing = False
        self._audio_blocks = []
        self._audio_total_samples = 0
        self._audio_buffer_ceiling = 0
        self._stream = None
        self._max_duration_timer = None
        self._lock = threading.Lock()
        # Serializes start_recording / stop_and_transcribe so a fast
        # release can't tear down the stream before start has opened it.
        # The listener thread never holds this — only the worker threads do.
        self._record_lifecycle_lock = threading.Lock()
        self._record_start_time = None
        self._listener = None
        self._shutdown = threading.Event()
        # Set when a stream teardown had to be abandoned mid-call, meaning a
        # thread is still stuck inside PortAudio and the library must not be
        # torn down underneath it.
        self._audio_subsystem_suspect = False
        self._last_stream_status_log = 0.0
        # When the current stop/transcribe pass started, so Escape can tell
        # a slow transcription from a stalled one.
        self._stop_started_at = None
        # Bumped by force_reset so an abandoned transcription that finishes
        # later doesn't paste text into whatever the user is doing by then.
        self._dictation_seq = 0

        # Streaming transcription state (set up per-recording when enabled).
        # _streamer_cut_lock serialises "feed a chunk and advance the cut
        # index" between the watcher thread and the finalize path, so a
        # chunk committed at the moment of key release can't also be
        # covered by the leftover feed (which would transcribe it twice).
        self._streamer = None
        self._streamer_last_cut = 0
        self._streamer_cut_lock = threading.Lock()

        # Monotonic counter so the async clipboard restore from a previous
        # typing can detect that a newer typing has happened and skip its
        # write rather than clobbering the new clipboard content.
        self._typing_seq = 0
        self._typing_seq_lock = threading.Lock()

        # Overlay
        self._overlay_proc = None
        self._overlay_lock = threading.Lock()
        self._current_rms = 0.0

        # Model lifecycle. The Whisper model is unloaded from GPU memory
        # after a configurable idle stretch and reloaded on the next
        # dictation. _transcribe_lock serialises model load/inference so a
        # background wake can't race a streaming chunk into a double load.
        self._model_loaded = False
        self._last_activity = time.time()
        self._transcribe_lock = threading.Lock()

    def _start_overlay(self):
        """Spawn the overlay process if enabled and binary exists."""
        style = self.config.get('overlay_style', 'translucent')
        if style == 'off':
            return
        overlay_bin = paths.bundle_resources_dir() / 'overlay'
        if not overlay_bin.exists():
            log("  Overlay binary not found — run: swiftc overlay.swift -o overlay -parse-as-library -framework SwiftUI -framework AppKit -O")
            return
        args = [str(overlay_bin)]
        if style == 'solid':
            args.append('--solid')
        self._overlay_proc = subprocess.Popen(
            args,
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        log("  Overlay ready.")

    def _stop_overlay(self):
        if self._overlay_proc:
            self._overlay_send({"cmd": "quit"})
            try:
                self._overlay_proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self._overlay_proc.kill()
            self._overlay_proc = None

    def _overlay_send(self, msg):
        with self._overlay_lock:
            if self._overlay_proc and self._overlay_proc.poll() is None:
                try:
                    line = json.dumps(msg) + "\n"
                    self._overlay_proc.stdin.write(line.encode())
                    self._overlay_proc.stdin.flush()
                except (BrokenPipeError, OSError):
                    pass

    def _overlay_level_sender(self):
        """Send audio levels to the overlay at ~30fps while recording."""
        while self._recording:
            self._overlay_send({"cmd": "level", "v": round(self._current_rms, 4)})
            time.sleep(0.033)

    def _key_watchdog(self):
        """Force-stop if the trigger combo isn't actually held anymore.

        pynput's macOS event tap can drop release events: if a callback ever
        blocks for too long (e.g. a slow audio stream open), macOS throttles
        or disables the tap, and key-up events stop arriving. Without this,
        recording then runs until max_duration. Poll modifier flag state
        directly via Quartz so any missed release recovers within ~75ms.
        """
        try:
            from Quartz import (
                CGEventSourceFlagsState,
                kCGEventSourceStateCombinedSessionState,
            )
        except ImportError:
            return
        required_mask = 0
        for k in self._trigger_keys:
            m = _MODIFIER_FLAG_MASKS.get(k)
            if m is None:
                # Non-modifier trigger; flag-state polling won't work.
                return
            required_mask |= m
        # Small grace period — the user can legitimately release one key
        # a fraction of a second before the stream has finished opening.
        time.sleep(0.15)
        while self._recording and self._key_held:
            flags = CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState)
            if (flags & required_mask) != required_mask:
                log("Watchdog: trigger combo no longer held — forcing stop")
                with self._lock:
                    if not self._key_held:
                        return
                    self._key_held = False
                    self._processing = True
                self._combo_held.clear()
                if self._max_duration_timer:
                    self._max_duration_timer.cancel()
                    self._max_duration_timer = None
                threading.Thread(target=self.stop_and_transcribe, daemon=True).start()
                return
            time.sleep(0.075)

    def preload_whisper(self):
        log("  Importing MLX Whisper...")
        import mlx_whisper
        model = self.config['transcription_model']
        repo = MLX_MODELS[model]
        log(f"  Loading Whisper {model} into GPU memory...")
        try:
            silent = np.zeros(self.sample_rate, dtype=np.float32)
            language = 'en' if model.startswith('distil-') else self.config['language']
            with self._transcribe_lock:
                mlx_whisper.transcribe(silent, path_or_hf_repo=repo, verbose=None, language=language)
            self._model_loaded = True
            self._last_activity = time.time()
            log("  Whisper ready.")
        except Exception as e:
            # Full traceback at debug-level so future bundle-related failures
            # don't hide behind a one-line error string the way the SSL
            # FileNotFoundError did.
            log(f"  Failed to load Whisper model: {e}")
            log(f"  Traceback:\n{traceback.format_exc()}")
            log("  The model will be downloaded on first use (requires internet).")

    def _unload_whisper(self, idle_minutes):
        """Drop the Whisper model from GPU memory after an idle stretch.

        The next dictation reloads it: start_recording kicks a background
        wake as soon as the trigger is held, so most of the reload happens
        while the user is still speaking.
        """
        try:
            import gc
            import mlx.core as mx
            from mlx_whisper import transcribe as _mlx_transcribe
            with self._transcribe_lock:
                _mlx_transcribe.ModelHolder.model = None
                _mlx_transcribe.ModelHolder.model_path = None
                gc.collect()
                mx.clear_cache()
            self._model_loaded = False
            log(f"Whisper model unloaded after {idle_minutes:.0f}m idle — "
                f"next dictation reloads it")
        except Exception as e:
            log(f"Model unload failed: {e}")

    def _maybe_unload_model(self, now=None):
        """Unload the model if it's been idle past the configured threshold.

        Returns True when an unload happened. `model_idle_unload_minutes`
        <= 0 disables unloading entirely.
        """
        minutes = self.config.get('model_idle_unload_minutes', 120)
        if not minutes or minutes <= 0:
            return False
        if not self._model_loaded or self._recording or self._processing:
            return False
        now = now if now is not None else time.time()
        idle_minutes = (now - self._last_activity) / 60
        if idle_minutes < minutes:
            return False
        self._unload_whisper(idle_minutes)
        return True

    def _idle_monitor(self):
        """Check once a minute whether the model has gone idle."""
        while not self._shutdown.is_set():
            self._shutdown.wait(timeout=60)
            if self._shutdown.is_set():
                return
            try:
                self._maybe_unload_model()
            except Exception as e:
                log(f"Idle monitor error: {e}")

    def _wake_model(self):
        """Reload an unloaded model in the background during recording."""
        log("Waking Whisper model...")
        emit_event("state", state="recording", text="Recording… (waking speech model)")
        self.preload_whisper()

    def reload_config(self):
        """Re-read config.yaml and apply what can change without a restart.

        Covers everything except a mid-recording change: trigger keys,
        overlay on/off/style, model choice (preloaded in the background),
        streaming, typing, sound, devices, vocabulary and corrections all
        take effect immediately or on the next dictation. Invalid configs
        are rejected wholesale — the daemon keeps running on the old one.
        """
        if self._config_path is None:
            log("Config reload requested but no config path — ignoring")
            return
        try:
            new_config = load_config(self._config_path)
        except Exception as e:
            log(f"Config reload failed ({e}) — keeping current settings")
            emit_event("warning", message=f"Config reload failed: {e}")
            return
        errors, warnings = validate_config(new_config)
        if errors:
            for err in errors:
                log(f"  Config error: {err}")
            emit_event("warning", message="Config reload rejected — see logs")
            return
        for w in warnings:
            log(f"  Warning: {w}")

        # Don't swap state under an active dictation; wait briefly for idle.
        for _ in range(50):
            if not self._recording and not self._processing:
                break
            time.sleep(0.1)

        old = self.config
        self.config = new_config
        self.sample_rate = new_config['sample_rate']

        if new_config['trigger_key'] != old['trigger_key']:
            self._trigger_keys = {KEY_MAP[p] for p in new_config['trigger_key'].split('+')}
            self._combo_held.clear()

        if new_config['overlay_style'] != old['overlay_style']:
            if self._overlay_proc is not None:
                self._stop_overlay()
            self._start_overlay()  # no-op when the new style is 'off'

        if new_config['transcription_model'] != old['transcription_model']:
            # Load the new model off-thread; ModelHolder swaps it in.
            self._model_loaded = False
            threading.Thread(target=self.preload_whisper, daemon=True).start()

        log("Config reloaded")
        emit_event("state", state="ready")

    def _prewarm_audio(self):
        """Open and immediately close a throwaway InputStream so CoreAudio
        initialises its HAL and device cache before the first real recording.
        Eliminates the 200-400ms first-keypress lag and surfaces stale-device
        errors at startup rather than on the first dictation.
        """
        kwargs = {
            'samplerate': self.sample_rate,
            'channels': 1,
            'dtype': 'float32',
            'blocksize': self._AUDIO_BLOCKSIZE,
        }
        device = self.config.get('input_device')
        if device:
            kwargs['device'] = device
        try:
            stream = sd.InputStream(**kwargs)
            stream.start()
            # Bounded teardown — a wedged device here must not stop the
            # daemon from finishing startup.
            self._teardown_stream(stream, context="pre-warm")
        except Exception as e:
            log(f"  Audio pre-warm skipped ({e})")

    def _type_unicode(self, text):
        """Inject text directly via Quartz unicode keyboard events.

        Bypasses the clipboard entirely — fast, leaves clipboard untouched, and
        avoids interactions with any Cmd+V handlers in the focused app. ~20
        chars per event is the documented max.
        """
        from Quartz import (
            CGEventCreateKeyboardEvent,
            CGEventKeyboardSetUnicodeString,
            CGEventPost,
            kCGHIDEventTap,
        )
        chunk_size = 20
        for i in range(0, len(text), chunk_size):
            chunk = text[i:i + chunk_size]
            event_down = CGEventCreateKeyboardEvent(None, 0, True)
            CGEventKeyboardSetUnicodeString(event_down, len(chunk), chunk)
            CGEventPost(kCGHIDEventTap, event_down)
            event_up = CGEventCreateKeyboardEvent(None, 0, False)
            CGEventKeyboardSetUnicodeString(event_up, len(chunk), chunk)
            CGEventPost(kCGHIDEventTap, event_up)

    # How long the dictation stays on the clipboard before the user's previous
    # content is put back. The paste is asynchronous from our point of view: we
    # synthesise Cmd+V, and the focused app reads the pasteboard whenever it
    # gets round to processing that key event. Restore too early and a busy app
    # (browser, Electron, IDE) reads *after* the restore and pastes the user's
    # old clipboard instead of the dictation.
    _CLIPBOARD_RESTORE_DELAY = 1.5

    def type_at_cursor(self, text):
        if (self.config.get('fast_typing_enabled', True)
                and len(text) <= self.config.get('fast_typing_max_chars', 80)):
            # Short text path: direct unicode injection, no clipboard, no sleeps
            log(f"Typing... ({len(text)} chars, unicode events)")
            self._type_unicode(text)
            return

        # Long text path: clipboard paste with async restore
        log(f"Typing... ({len(text)} chars, clipboard paste)")
        from pynput.keyboard import Controller, Key
        kb = Controller()

        with self._typing_seq_lock:
            self._typing_seq += 1
            my_seq = self._typing_seq

        old_clipboard = _get_clipboard_text()
        if not _set_clipboard_text_verified(text):
            # Never send Cmd+V here: the clipboard still holds the user's
            # previous content, so pasting would insert the wrong text and
            # look like the dictation was lost.
            log("Clipboard write refused — not pasting. Text is in the menu "
                "under Recent Transcripts.")
            emit_event("warning", message="Clipboard unavailable — text kept in Recent Transcripts")
            return
        time.sleep(self.config['release_delay'])

        # Last check before the keystroke: if anything overwrote the clipboard
        # in the meantime, pasting now would insert that instead.
        if _get_clipboard_text() != text:
            log("Clipboard changed before paste — not pasting. Text is in the "
                "menu under Recent Transcripts.")
            emit_event("warning", message="Clipboard was overwritten — text kept in Recent Transcripts")
            return

        # Use pynput to send Cmd+V (same accessibility grant as the listener)
        kb.press(Key.cmd)
        kb.press('v')
        kb.release('v')
        kb.release(Key.cmd)

        # Restore the original clipboard in the background so we return
        # immediately.
        def _restore():
            delay = self.config.get('clipboard_restore_delay',
                                    self._CLIPBOARD_RESTORE_DELAY)
            if delay <= 0:
                return  # user opted out; the dictation stays on the clipboard
            time.sleep(delay)
            with self._typing_seq_lock:
                if self._typing_seq != my_seq:
                    return  # a newer dictation owns the clipboard now
            # Only put the old content back if our dictation is still there.
            # Anything else means the user (or another app) copied something
            # during the wait, and restoring would clobber it.
            if _get_clipboard_text() != text:
                return
            _set_clipboard_text(old_clipboard)
        threading.Thread(target=_restore, daemon=True).start()

    def transcribe(self, audio, model_name=None):
        import mlx_whisper
        model_key = model_name or self.config['transcription_model']
        repo = MLX_MODELS[model_key]
        language = 'en' if model_key.startswith('distil-') else self.config['language']
        kwargs = {
            'path_or_hf_repo': repo,
            'verbose': None,
            'language': language,
            # Reduce hallucination spread across segments. Each segment is
            # transcribed independently rather than conditioning on prior text.
            'condition_on_previous_text': False,
        }
        vocab = self.config.get('vocabulary', []) or []
        if vocab:
            kwargs['initial_prompt'] = "Vocabulary: " + ", ".join(vocab) + "."
        with self._transcribe_lock:
            result = mlx_whisper.transcribe(audio, **kwargs)
        self._model_loaded = True
        self._last_activity = time.time()
        text = result.get('text', '').strip()
        return _apply_phonetic_corrections(text, self.config.get('phonetic_corrections') or {})

    # Hard ceiling on the in-memory audio buffer. The max_duration timer
    # normally stops a recording at 5 min; this is a defence-in-depth cap
    # so a stuck `_recording=True` (e.g. the timer never fires for some
    # reason) can't grow the buffer until the process OOMs. Computed from
    # 2× max_duration, capped to 30 minutes.
    _AUDIO_BUFFER_CEILING_FACTOR = 2
    _AUDIO_BUFFER_HARD_CAP_SECONDS = 30 * 60

    # Audio callback block size, in frames. Left unset, PortAudio picks a
    # very small buffer and our Python callback then overruns its real-time
    # deadline roughly once a second (visible in Console as CoreAudio
    # "Audio IO Overload" reports). 512 frames = 32ms at 16kHz, which
    # matches the ~30fps level feed the pill's waveform consumes.
    _AUDIO_BLOCKSIZE = 512

    # How long a stream teardown is allowed to take before we abandon it.
    # A healthy stop+close is ~0.1s.
    _STREAM_TEARDOWN_TIMEOUT = 1.5

    # If not one audio frame has arrived this long after the stream started,
    # treat the device's IO thread as dead and reopen the stream once.
    _CAPTURE_HEALTH_DELAY = 0.4

    # How long the stop path may be in flight before Escape is allowed to
    # abandon it. Normal transcription of a short clip is 1-2s; a 5 minute
    # clip can take ~20s, so this only fires when the user has decided
    # something is wrong.
    _STALL_ESCAPE_THRESHOLD = 5.0

    def _audio_callback(self, indata, frames, time_info, status):
        if status:
            self._note_stream_status(status)
        if not self._recording:
            return
        if self._audio_total_samples >= self._audio_buffer_ceiling:
            # Safety net: max_duration timer should have fired by now.
            # Stop appending; the existing release/auto-stop flow will
            # tear the stream down on the next user release or timer.
            if self._recording:
                log(f"Audio buffer ceiling reached "
                    f"({self._audio_buffer_ceiling / self.sample_rate:.0f}s) — stopping")
                self._recording = False
            return
        self._audio_blocks.append(indata.copy())
        self._audio_total_samples += frames
        self._current_rms = float(np.sqrt(np.mean(indata ** 2)))

    def _note_stream_status(self, status):
        """Log PortAudio status flags (overflow, etc.), rate-limited.

        These are the app-side symptom of the CoreAudio overloads that
        precede a dead IO thread, so they're worth having in the log — but
        they can arrive on every callback, hence the 5s throttle.
        """
        now = time.time()
        if now - self._last_stream_status_log < 5.0:
            return
        self._last_stream_status_log = now
        log(f"Audio stream status: {status}")

    def _open_input_stream(self):
        kwargs = {
            'samplerate': self.sample_rate,
            'channels': 1,
            'dtype': 'float32',
            'blocksize': self._AUDIO_BLOCKSIZE,
            'callback': self._audio_callback,
        }
        device = self.config.get('input_device')
        if device:
            kwargs['device'] = device
        return sd.InputStream(**kwargs)

    def _teardown_stream(self, stream, context="stop"):
        """Stop and close an input stream without ever blocking the caller.

        PortAudio's blocking stop waits for the audio callback to
        acknowledge. When macOS has killed the device's IO thread that
        callback never arrives, `stop()` never returns, and the whole
        daemon wedges behind it: the pill stays on "recording", the
        transcription never runs, the trigger key goes dead and only a
        restart recovers. So: `abort()` (we have no output buffers worth
        draining) on a throwaway thread, and carry on if it overruns.

        Returns True if the stream closed cleanly.
        """
        done = threading.Event()

        def _close():
            try:
                stream.abort()
            except Exception as e:
                log(f"  stream.abort() failed ({context}): {e}")
            try:
                stream.close()
            except Exception as e:
                log(f"  stream.close() failed ({context}): {e}")
            done.set()

        threading.Thread(target=_close, daemon=True).start()
        if done.wait(self._STREAM_TEARDOWN_TIMEOUT):
            return True
        # The teardown thread is still stuck inside PortAudio. Leave it
        # there — it's a daemon thread — but remember that the audio
        # subsystem can't be trusted, so we don't call sd._terminate()
        # underneath a thread that's still executing PortAudio code.
        self._audio_subsystem_suspect = True
        log(f"Audio stream did not close within {self._STREAM_TEARDOWN_TIMEOUT}s "
            f"({context}) — abandoning it. Microphone may need an app restart.")
        emit_event("warning", message="Audio device stopped responding — recording abandoned")
        return False

    def start_recording(self):
        self._recording = True
        self._audio_blocks = []
        self._audio_total_samples = 0
        self._record_start_time = time.time()

        max_dur = self.config.get('max_duration') or 0
        ceiling_seconds = min(
            max(max_dur * self._AUDIO_BUFFER_CEILING_FACTOR, 60),
            self._AUDIO_BUFFER_HARD_CAP_SECONDS,
        )
        ceiling_samples = int(self.sample_rate * ceiling_seconds)
        self._audio_buffer_ceiling = ceiling_samples

        try:
            try:
                self._stream = self._open_input_stream()
                self._stream.start()
            except Exception as first_err:
                # PortAudio's device cache can go stale after sleep/wake or audio
                # device changes (Bluetooth, headphones, display sleep). Reset
                # PortAudio and try once more before giving up.
                log(f"Audio stream failed ({first_err}); retrying...")
                self._reset_portaudio()
                self._stream = self._open_input_stream()
                self._stream.start()
            log("Recording...")
            self._last_activity = time.time()
            emit_event("state", state="recording")
            self._overlay_send({"cmd": "show", "state": "recording"})
            # If the model was unloaded for idleness, start reloading it now
            # so most of the wake happens while the user is still speaking.
            if not self._model_loaded:
                threading.Thread(target=self._wake_model, daemon=True).start()
            threading.Thread(target=self._overlay_level_sender, daemon=True).start()
            # Backup for missed pynput release events — see _key_watchdog.
            threading.Thread(target=self._key_watchdog, daemon=True).start()
            # Backup for a device that starts but never delivers audio.
            threading.Thread(target=self._capture_health_check, daemon=True).start()

            # Streaming transcription: spin up worker + watcher when enabled.
            if self.config.get('streaming_transcribe_enabled', True):
                self._streamer = StreamingTranscriber(self.transcribe)
                self._streamer_last_cut = 0
                threading.Thread(target=self._streaming_watcher, daemon=True).start()
            else:
                self._streamer = None

            if self.config['sound_enabled']:
                play_sound('start')
            if self.config['max_duration'] > 0:
                # Cancel any timer left over from a previous recording. A
                # release that lands while this method is still opening the
                # stream cancels the *old* timer, so without this the one we
                # create below outlives its recording and later force-stops
                # an unrelated dictation mid-sentence.
                if self._max_duration_timer:
                    self._max_duration_timer.cancel()
                self._max_duration_timer = threading.Timer(
                    self.config['max_duration'], self._auto_stop
                )
                self._max_duration_timer.start()
        except Exception as e:
            log(f"Error: Failed to start recording: {e}")
            with self._lock:
                self._recording = False
                self._key_held = False
                self._processing = False
            self._combo_held.clear()
            self._overlay_send({"cmd": "hide"})
            emit_event("error", message=f"Failed to start recording: {e}")

    def _reset_portaudio(self):
        """Re-initialise PortAudio to clear a stale device cache.

        Skipped when a previous teardown was abandoned: a thread may still
        be executing inside PortAudio, and terminating the library under it
        can take the whole process down.
        """
        if self._audio_subsystem_suspect:
            log("  Skipping PortAudio reset — a previous teardown is still stuck")
            return
        try:
            sd._terminate()
            sd._initialize()
        except Exception as reset_err:
            log(f"  PortAudio reset failed: {reset_err}")

    def _capture_health_check(self):
        """Reopen the stream if the device started but delivers no audio.

        macOS sometimes acknowledges the start and then never runs our IO
        proc — seen after the rapid open/close cycle of back-to-back
        dictations. The old behaviour was to record silence for as long as
        the user spoke and lose the whole dictation, so catch it early
        while only a fraction of a second has been missed.
        """
        time.sleep(self._CAPTURE_HEALTH_DELAY)
        if not self._recording or not self._key_held:
            return
        if self._audio_total_samples > 0:
            return
        log(f"No audio {self._CAPTURE_HEALTH_DELAY:.2f}s after start — "
            f"reopening the input stream")
        with self._record_lifecycle_lock:
            if not self._recording or not self._key_held:
                return
            if self._audio_total_samples > 0:
                return  # started flowing while we waited for the lock
            stale = self._stream
            self._stream = None
            if stale is not None:
                self._teardown_stream(stale, context="dead-device reopen")
            self._reset_portaudio()
            try:
                self._stream = self._open_input_stream()
                self._stream.start()
                log("  Input stream reopened.")
            except Exception as e:
                # Leave the recording running: release will find no audio
                # and report it cleanly rather than wedging.
                log(f"  Input stream reopen failed: {e}")
                emit_event("warning", message="Microphone unavailable — nothing recorded")

    def force_reset(self, reason):
        """Last-resort recovery: discard everything and return to ready.

        For when the stop path has stalled somewhere we can't unblock. The
        current dictation is lost either way; this at least leaves the app
        usable without restarting it.
        """
        log(f"Force reset ({reason}) — discarding in-flight dictation")
        self._dictation_seq += 1
        if self._max_duration_timer:
            self._max_duration_timer.cancel()
            self._max_duration_timer = None
        stale = self._stream
        self._stream = None
        with self._lock:
            self._recording = False
            self._key_held = False
            self._processing = False
        self._combo_held.clear()
        self._audio_blocks = []
        self._audio_total_samples = 0
        if stale is not None:
            self._teardown_stream(stale, context="force reset")
        if self._streamer is not None:
            try:
                self._streamer.drain()
            except Exception:
                pass
            self._streamer = None
        self._overlay_send({"cmd": "hide"})
        log("Ready")
        emit_event("state", state="ready")

    def _streaming_watcher(self):
        """Watch the live audio buffer for silence gaps and feed completed
        chunks to the streamer. Runs on a background thread for the duration
        of the recording.
        """
        # Minimum chunk length to bother streaming. Defense-in-depth alongside
        # the silence detector's min_speech_hops; should never fire in practice
        # but cheap insurance.
        min_chunk_samples = int(self.sample_rate * 1.5)
        while self._recording:
            time.sleep(0.25)
            streamer = self._streamer  # snapshot to avoid race with main thread
            if not self._audio_blocks or streamer is None:
                continue
            # list.copy is atomic in CPython; concatenate the snapshot.
            blocks = list(self._audio_blocks)
            try:
                audio = np.concatenate(blocks, axis=0).flatten()
            except ValueError:
                continue
            cut = silence_gap_index(audio, self.sample_rate, self._streamer_last_cut)
            if cut is None or cut <= self._streamer_last_cut:
                continue
            chunk = audio[self._streamer_last_cut:cut]
            if chunk.size < min_chunk_samples:
                continue
            # Commit (feed + advance the cut index) under the cut lock, and
            # re-check _recording inside it: if the finalize path has started,
            # it owns everything from the current cut index onwards, and
            # feeding here as well would transcribe this chunk twice.
            with self._streamer_cut_lock:
                if not self._recording:
                    return
                self._streamer_last_cut = cut
                idx = streamer.feed(chunk)
            log(f"Streaming chunk {idx}: {chunk.size / self.sample_rate:.1f}s")

    def _auto_stop(self):
        self._max_duration_timer = None
        if not self._key_held:
            # Timer outlived its recording (see start_recording) — nothing
            # to stop, and stopping anything now would cut short whatever
            # dictation is in progress.
            log("Max duration timer fired with no recording in progress — ignored")
            return
        log(f"Max duration reached ({self.config['max_duration']}s) — stopping")
        with self._lock:
            if not self._key_held:
                return
            self._key_held = False
            self._processing = True
        self._combo_held.clear()
        threading.Thread(target=self.stop_and_transcribe, daemon=True).start()

    def stop_and_transcribe(self):
        self._stop_started_at = time.time()
        try:
            # Wait for any in-flight start_recording to finish opening the
            # stream before we tear it down. on_press dispatches start to a
            # worker thread (so the listener callback returns fast), so a
            # quick release can race ahead of stream open without this lock.
            with self._record_lifecycle_lock:
                self._do_stop_and_transcribe()
        except Exception as e:
            log(f"Error during transcription: {e}")
            log(traceback.format_exc())
            emit_event("error", message=f"Error during transcription: {e}")
        finally:
            self._stop_started_at = None
            self._overlay_send({"cmd": "hide"})
            self._processing = False
            log("Ready")
            emit_event("state", state="ready")

    def _do_stop_and_transcribe(self):
        total_t0 = time.time()
        seq = self._dictation_seq

        # Stop recording
        self._recording = False
        record_duration = time.time() - self._record_start_time if self._record_start_time else 0

        # A leftover timer here would fire mid-way through a later dictation.
        if self._max_duration_timer:
            self._max_duration_timer.cancel()
            self._max_duration_timer = None

        if self._stream:
            stale = self._stream
            self._stream = None
            self._teardown_stream(stale, context="stop")

        def _discard_streamer():
            """Tear down the streamer worker without using its results."""
            if self._streamer is None:
                return
            try:
                self._streamer.drain()
            except Exception:
                pass
            self._streamer = None

        if not self._audio_blocks:
            log("No audio captured")
            _discard_streamer()
            return

        audio = np.concatenate(self._audio_blocks, axis=0).flatten()
        raw_audio_duration = len(audio) / self.sample_rate
        whisper_model = self.config['transcription_model']

        if raw_audio_duration < self.config['min_duration']:
            log(f"Too short ({raw_audio_duration:.1f}s), skipping")
            _discard_streamer()
            return

        # Check audio energy
        rms = np.sqrt(np.mean(audio ** 2))
        if rms < SILENCE_RMS_THRESHOLD:
            log(f"Too quiet (RMS={rms:.4f}), skipping")
            _discard_streamer()
            return

        streaming_active = self._streamer is not None

        # Skip silence trim when streaming — chunks already use natural silence
        # boundaries, and the trim operates on the full buffer the streamer
        # has already been fed pieces of.
        if not streaming_active and self.config.get('trim_silence_enabled', True):
            trimmed_audio, saved_samples = trim_silence(audio, self.sample_rate)
            if saved_samples > 0:
                before = len(audio) / self.sample_rate
                after = len(trimmed_audio) / self.sample_rate
                saved_ms = int(saved_samples * 1000 / self.sample_rate)
                audio = trimmed_audio
                log(f"Trimmed silence: {before:.2f}s -> {after:.2f}s (saved {saved_ms}ms)")

        audio_duration = len(audio) / self.sample_rate

        # Transcribe
        emit_event("state", state="transcribing")
        self._overlay_send({"cmd": "state", "s": "transcribing"})
        transcribe_t0 = time.time()
        if streaming_active:
            # Feed the leftover (post-final-cut) audio and drain the worker.
            # The cut lock pairs with the watcher's commit: whatever the
            # watcher committed before this point is excluded from the
            # leftover, and nothing can be committed after it.
            with self._streamer_cut_lock:
                leftover = audio[self._streamer_last_cut:]
                fed_chunks = self._streamer.chunk_count
                # A near-silent tail after real chunks is just trailing
                # quiet — transcribing it alone only invites hallucinations.
                leftover_rms = (float(np.sqrt(np.mean(leftover ** 2)))
                                if leftover.size else 0.0)
                if leftover.size > 0 and not (
                        fed_chunks > 0 and leftover_rms < SILENCE_RMS_THRESHOLD):
                    self._streamer.feed(leftover)
            log(f"Streaming finalize: {audio_duration:.1f}s in {self._streamer.chunk_count} chunk(s) | whisper={whisper_model}")
            chunks = self._streamer.drain()
            streamer_failed = self._streamer.failed
            self._streamer = None
            if streamer_failed:
                # A chunk died mid-stream; re-run the whole clip in one
                # pass rather than silently dropping that sentence.
                log("Streamed chunk failed — falling back to single-pass transcription")
                text = self.transcribe(audio)
            else:
                # Clean each chunk individually — boundary silences are prime
                # hallucination fodder for streaming.
                cleaned_chunks = [clean_hallucinations(c) for c in chunks]
                text = ' '.join(c for c in cleaned_chunks if c)
        else:
            log(f"Transcribing {audio_duration:.1f}s | whisper={whisper_model}")
            text = self.transcribe(audio)
        # Strip trailing hallucinations from the joined / single-pass result.
        text_before_clean = text
        text = clean_hallucinations(text)
        transcribe_elapsed = time.time() - transcribe_t0

        if not text:
            if text_before_clean and text_before_clean.strip():
                log(f"Hallucination filtered: \"{text_before_clean}\" ({transcribe_elapsed:.1f}s)")
            else:
                log(f"No transcription produced ({transcribe_elapsed:.1f}s)")
            return

        # Filter hallucinations
        if text.lower().strip().rstrip('.') in {p.rstrip('.') for p in HALLUCINATION_PHRASES}:
            log(f"Hallucination filtered: \"{text}\"")
            return

        log(f"Raw ({len(text.split())}w): {text}")
        emit_event("last_text", text=text)

        # Persist runtime stats and recent-transcripts list.
        try:
            update_stats_and_recent(text)
            emit_event("stats", usage=load_stats())
        except Exception as e:
            log(f"Stats update failed: {e}")

        total_elapsed = time.time() - total_t0
        log(f"Done: record={record_duration:.1f}s transcribe={transcribe_elapsed:.1f}s total={total_elapsed:.1f}s")

        if self.config['sound_enabled']:
            play_sound('done')

        if seq != self._dictation_seq:
            # This dictation was abandoned (Escape / force reset) while we
            # were still working. Pasting now would drop text into whatever
            # the user moved on to.
            log("Abandoned dictation finished late — not typing")
            return

        # Typing is too brief to be a useful pill state — keep the previous
        # state visible (transcribing/cleaning) right up until the overlay
        # hides in the finally block.
        self.type_at_cursor(text)

    def cancel_recording(self):
        """Discard the in-progress recording without transcribing or typing."""
        if not self._recording or not self._key_held:
            return

        log("Recording cancelled")

        if self._max_duration_timer:
            self._max_duration_timer.cancel()
            self._max_duration_timer = None

        with self._lock:
            self._key_held = False
            self._recording = False

        if self._stream:
            stale = self._stream
            self._stream = None
            self._teardown_stream(stale, context="cancel")

        if self._streamer is not None:
            try:
                self._streamer.drain()
            except Exception:
                pass
            self._streamer = None

        self._audio_blocks = []
        self._combo_held.clear()
        self._overlay_send({"cmd": "hide"})
        emit_event("state", state="ready")

    def on_press(self, key):
        if key == keyboard.Key.esc:
            # Escape must never do the work on this thread: cancelling
            # touches the audio device, and a slow call here gets the
            # keyboard event tap throttled by macOS.
            if self._recording and self._key_held:
                threading.Thread(target=self.cancel_recording, daemon=True).start()
            elif self._processing or self._recording:
                # The pill is still up but there's nothing to cancel
                # cleanly, so the stop path is stalled. Only step in once
                # it's clearly overdue — a legitimate transcription of a
                # long clip takes a few seconds.
                started = self._stop_started_at
                stalled_for = time.time() - started if started else None
                if stalled_for is None or stalled_for >= self._STALL_ESCAPE_THRESHOLD:
                    detail = (f"Escape, stalled {stalled_for:.0f}s"
                              if stalled_for is not None else "Escape")
                    threading.Thread(target=self.force_reset, args=(detail,),
                                     daemon=True).start()
            return
        if key in self._trigger_keys:
            self._combo_held.add(key)
            if self._combo_held >= self._trigger_keys and not self._key_held and not self._processing:
                with self._lock:
                    if self._key_held or self._processing:
                        return
                    self._key_held = True
                # Run start_recording on a worker thread so this callback
                # returns immediately. If we block here, macOS throttles
                # the keyboard event tap and subsequent key release events
                # get dropped — which is why recording sometimes wouldn't
                # stop on release.
                threading.Thread(target=self._start_recording_worker, daemon=True).start()

    def _start_recording_worker(self):
        with self._record_lifecycle_lock:
            if not self._key_held:
                # User released before we got the lock; nothing to start.
                return
            self.start_recording()

    def on_release(self, key):
        if key in self._trigger_keys:
            self._combo_held.discard(key)
            if self._key_held:
                if self._max_duration_timer:
                    self._max_duration_timer.cancel()
                    self._max_duration_timer = None
                with self._lock:
                    self._key_held = False
                    self._processing = True
                threading.Thread(target=self.stop_and_transcribe, daemon=True).start()

    def shutdown(self):
        """Gracefully shut down the daemon."""
        log("Shutting down...")
        emit_event("state", state="stopped")
        self._shutdown.set()
        self._stop_overlay()
        if self._stream:
            stale = self._stream
            self._stream = None
            self._teardown_stream(stale, context="shutdown")
        if self._listener:
            self._listener.stop()

    def run(self):
        # Handle SIGTERM/SIGINT for graceful shutdown. SIGHUP re-reads the
        # config so settings changes apply without a restart; the work runs
        # on a thread because signal handlers must return fast.
        signal.signal(signal.SIGTERM, lambda *_: self.shutdown())
        signal.signal(signal.SIGINT, lambda *_: self.shutdown())
        signal.signal(
            signal.SIGHUP,
            lambda *_: threading.Thread(target=self.reload_config, daemon=True).start(),
        )

        emit_event("state", state="loading", text="Starting up...")
        self.preload_whisper()
        self._prewarm_audio()
        self._start_overlay()

        trigger_name = ' + '.join(p.replace('_', ' ').title() for p in self.config['trigger_key'].split('+'))
        log(f"Ready! Hold {trigger_name} to dictate, release to transcribe.")
        emit_event("state", state="ready")

        self._listener = keyboard.Listener(on_press=self.on_press, on_release=self.on_release)
        self._listener.start()
        threading.Thread(target=self._idle_monitor, daemon=True).start()

        # Wait for shutdown signal or listener to stop
        while not self._shutdown.is_set() and self._listener.is_alive():
            self._shutdown.wait(timeout=0.5)

        self._listener.stop()


def check_accessibility():
    """Check if the process has macOS Accessibility permission."""
    try:
        from ApplicationServices import AXIsProcessTrusted
        if not AXIsProcessTrusted():
            log("  Accessibility permission required!")
            log("  Grant access: System Settings > Privacy & Security > Accessibility")
            log("  If Open Whisper is already listed, remove it and re-add it —")
            log("  the grant goes stale whenever the app is rebuilt/reinstalled.")
            emit_event(
                "permission",
                message="Accessibility needed — remove and re-add the app",
            )
            return False
    except ImportError:
        pass  # Can't check — proceed and hope for the best
    return True


def check_microphone():
    """Check microphone is available and request permission if needed."""
    try:
        import sounddevice as sd
        default_input = sd.query_devices(kind='input')
        if default_input is None:
            log("  No microphone found!")
            emit_event("permission", message="No microphone found — check input device")
            return False
    except Exception as e:
        log(f"  Microphone check failed: {e}")
        emit_event("permission", message="Microphone unavailable — check input device")
        return False

    # Request microphone permission (triggers macOS prompt if not yet granted)
    try:
        import objc
        AVFoundation = objc.loadBundle(
            'AVFoundation', {},
            '/System/Library/Frameworks/AVFoundation.framework',
        )
        AVCaptureDevice = objc.lookUpClass('AVCaptureDevice')
        status = AVCaptureDevice.authorizationStatusForMediaType_('soun')
        if status == 0:  # notDetermined — request permission
            log("  Requesting microphone permission...")
            import threading
            granted_event = threading.Event()

            def handler(granted):
                if not granted:
                    log("  Microphone permission denied!")
                granted_event.set()

            AVCaptureDevice.requestAccessForMediaType_completionHandler_('soun', handler)
            granted_event.wait(timeout=30)
            status = AVCaptureDevice.authorizationStatusForMediaType_('soun')

        if status != 3:  # not authorized
            log("  Microphone permission not granted!")
            log("  Grant access: System Settings > Privacy & Security > Microphone")
            emit_event(
                "permission",
                message="Microphone permission needed — see System Settings",
            )
            return False
    except Exception:
        pass  # Can't check — proceed anyway

    return True


def main():
    parser = argparse.ArgumentParser(description="Open Whisper")
    parser.add_argument('--config', type=str, help="Path to config.yaml")
    parser.add_argument('--check', action='store_true', help="Run startup checks and exit")
    args = parser.parse_args()

    if args.config:
        config_path = Path(args.config)
    else:
        config_path = paths.state_dir() / 'config.yaml'

    if not config_path.exists():
        log(f"Config not found: {config_path}")
        sys.exit(1)

    log("Open Whisper starting...")
    log(f"  Config: {config_path}")

    try:
        config = load_config(config_path)
    except yaml.YAMLError as e:
        # Malformed YAML — surface a clean structured event so the menu bar
        # can show "Config error: …" instead of a stack trace getting lost
        # in stderr.
        msg = f"YAML syntax error in {config_path.name}: {e}"
        log(f"  Config error: {msg}")
        emit_event("config_error", message=msg)
        sys.exit(1)
    except (OSError, IOError) as e:
        msg = f"Could not read {config_path}: {e}"
        log(f"  Config error: {msg}")
        emit_event("config_error", message=msg)
        sys.exit(1)
    except Exception as e:
        msg = f"Unexpected error loading {config_path.name}: {e}"
        log(f"  Config error: {msg}")
        emit_event("config_error", message=msg)
        sys.exit(1)

    # Validate config before starting
    errors, warnings = validate_config(config)
    if errors:
        for e in errors:
            log(f"  Config error: {e}")
            emit_event("config_error", message=e)
        sys.exit(1)
    for w in warnings:
        log(f"  Warning: {w}")
        emit_event("warning", message=w)

    if args.check:
        ok = True
        log("Running startup checks...")
        if not check_accessibility():
            ok = False
        if not check_microphone():
            ok = False
        try:
            import mlx_whisper  # noqa: F401
        except Exception as e:
            log(f"  Whisper import failed: {e}")
            emit_event("error", message=f"Whisper import failed: {e}")
            ok = False

        if config.get('overlay_style', 'translucent') != 'off':
            overlay_bin = paths.bundle_resources_dir() / 'overlay'
            if not overlay_bin.exists():
                log("  Overlay enabled but binary not found (run setup.sh).")
                emit_event("warning", message="Overlay enabled but binary not found")

        if ok:
            log("Startup checks passed.")
            emit_event("state", state="ready", text="Startup checks passed")
            sys.exit(0)
        log("Startup checks failed.")
        emit_event("error", message="Startup checks failed")
        sys.exit(1)

    # Permission checks
    if not check_accessibility():
        sys.exit(1)
    if not check_microphone():
        sys.exit(1)

    daemon = OpenWhisper(config, config_path=config_path)
    daemon.run()


if __name__ == '__main__':
    main()
