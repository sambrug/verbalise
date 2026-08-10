# Open Whisper

Local SuperWhisper-like voice dictation for macOS. Hold a key to speak, release to have text appear at your cursor.

Runs entirely on-device using MLX Whisper on Apple Silicon GPU. No accounts, no API keys, and no network traffic after the one-time model download.

## Features

- **Hold-to-dictate anywhere** - hold a trigger key (default Right Shift; any modifier key or combo), speak, release. The transcript is typed into whatever app has focus.
- **Streaming transcription** - long dictations are transcribed chunk by chunk at natural pauses while you're still speaking, so the wait after release stays at a second or two regardless of how long you talked. If a chunk fails, the whole recording is re-transcribed in one pass so nothing is lost.
- **Fully on-device** - audio never leaves the Mac. Eight Whisper model options from `tiny` to `large`, with `turbo` as the default sweet spot.
- **Custom vocabulary** - a list of domain terms (acronyms, names, jargon) that Whisper is biased towards recognising.
- **Phonetic corrections** - whole-word replacements applied after transcription for stubborn mishearings (e.g. `ethanol => FNOL`).
- **Hallucination filtering** - Whisper's silence artefacts ("thanks for watching", trailing ellipses, stuck-word repetition loops) are stripped before typing.
- **Smart typing** - short transcripts are injected as keystrokes (clipboard untouched); long ones paste via the clipboard with your previous clipboard verified and restored afterwards. Both paths refuse to paste the wrong thing if the clipboard is hijacked mid-flight.
- **Floating pill overlay** - a Liquid Glass pill shows a live waveform and timer while recording, and a pulse while transcribing.
- **Recent transcripts** - the last 10 dictations with timestamps, one click to copy. Lifetime word/recording stats.
- **Idle memory release** - the Whisper model unloads from GPU memory (~1.5GB) after a configurable idle period and rewarms in the background while you speak on the next dictation.
- **Live settings** - menu changes apply to the running daemon in under a second; the model stays loaded. No restarts.
- **Self-healing** - a supervisor auto-restarts the daemon with backoff if it dies; watchdogs recover from wedged audio devices, missed key releases, and dead microphones. Escape cancels a recording or force-resets a stalled one.
- **Launch at Login** - one menu toggle, registered natively with macOS.

## Quick Start

1. Open `Open Whisper.app` (from /Applications)
2. Grant **Accessibility** and **Microphone** permissions when prompted
3. A waveform icon appears in your menu bar
4. Hold your trigger key and speak
5. Release - text appears at your cursor

## Requirements

- macOS on Apple Silicon (M1/M2/M3/M4)
- **Accessibility** permission (System Settings > Privacy & Security > Accessibility > add Open Whisper.app)
- **Microphone** permission (prompted on first launch)

## How a dictation flows

Hold the trigger key: audio records and the pill shows a live waveform. While you speak, the streaming watcher looks for pauses of 400ms or more after at least 2 seconds of speech, slices completed chunks off and transcribes them in the background. On release, only the leftover tail needs transcribing. Hallucinations are stripped, phonetic corrections applied, and the text lands at your cursor. Recordings shorter than `min_duration` or containing only silence are discarded quietly.

## The Menu

Top level:

- **Status** - current state, including the trigger key when ready. Pins an actionable message if something is blocking (e.g. a permission problem); a message too long for one line scrolls instead of getting cut off
- **Last transcription** - click to copy to clipboard
- **Recent Transcripts** - last 10 with timestamps, click any to copy; Clear History
- **Restart** - hard-restart the daemon (settings changes don't need this)
- **Settings** / **Quit Open Whisper**

Settings, grouped by concern:

| Group | Items |
|-------|-------|
| *(unlabelled)* | Trigger Key, Launch at Login (shown when running the built app) |
| Recognition | Transcription Model, Vocabulary, Phonetic Corrections, Streaming Transcribe |
| Input / output | Input Device, Fast Typing |
| Feedback | Overlay (Off / Solid / Translucent), Sound Feedback |
| Info | Lifetime words and recordings, time saved typing, Open Config, View Logs |

Pickers show the current choice as a tick inside the submenu; Vocabulary and Phonetic Corrections show their counts as right-aligned badges. Hovering most Settings items shows a tooltip explaining what they do.

Every change applies live via a config reload - the daemon keeps running and the model stays warm.

## Configuration

Config lives at `~/Library/Application Support/Open Whisper/config.yaml` (Settings > Open Config). Most settings are also in the menu.

| Setting | Default | Description |
|---------|---------|-------------|
| `transcription_model` | `turbo` | Whisper model: `tiny`, `base`, `small`, `distil-medium`, `medium`, `distil-large`, `turbo`, `large` |
| `trigger_key` | `shift_r` | Single key or combo, e.g. `alt_r+shift_r` |
| `language` | `en` | Transcription language (ISO 639-1) |
| `min_duration` | `0.5` | Minimum recording length (seconds) |
| `max_duration` | `300` | Maximum recording length - auto-stops at this limit (seconds) |
| `release_delay` | `0.05` | Pause after key release before pasting (seconds) |
| `sample_rate` | `16000` | Audio sample rate |
| `sound_enabled` | `false` | Tink/pop sounds on record start/stop |
| `overlay_style` | `translucent` | Floating pill: `translucent` (Liquid Glass), `solid`, or `off`. (Legacy `overlay_enabled`/`overlay_translucent` configs are mapped automatically) |
| `vocabulary` | `[]` | Domain terms to bias Whisper recognition |
| `phonetic_corrections` | `{}` | Whole-word replacements applied after transcription |
| `input_device` | `null` | Audio input device name; `null` uses system default |

Under `advanced:`:

| Setting | Default | Description |
|---------|---------|-------------|
| `trim_silence_enabled` | `true` | Trim leading/trailing silence before transcription (single-pass mode) |
| `streaming_transcribe_enabled` | `true` | Transcribe in chunks at silence gaps while you speak |
| `model_idle_unload_minutes` | `120` | Unload the Whisper model from GPU memory after this long without a dictation; reloads while you speak on the next one. `0` keeps it loaded forever |
| `fast_typing_enabled` | `true` | Inject short transcripts as unicode keystrokes instead of clipboard paste |
| `fast_typing_max_chars` | `80` | Length threshold for the keystroke path |
| `clipboard_restore_delay` | `1.5` | Seconds the dictation stays on the clipboard after a paste before your previous clipboard is restored. Raise it if a slow app still pastes your old clipboard; `0` never restores |

## Trigger Keys

Single keys: `shift_r`, `shift_l`, `ctrl_r`, `ctrl_l`, `alt_r`, `alt_l`, `cmd_r`

Combos - join with `+`:
```yaml
trigger_key: alt_r+shift_r   # Right Option + Right Shift
```

## Logs & Troubleshooting

Logs are written to `~/Library/Logs/Open Whisper/daemon.log` (rotated at 10MB). Use **View Logs** in the menu to tail them live.

```
[14:32:01] Recording...
[14:32:03] Streaming chunk 0: 2.8s
[14:32:05] Streaming finalize: 4.2s in 2 chunk(s) | whisper=turbo
[14:32:05] Raw (14w): I was thinking we should look at the login page
[14:32:06] Done: record=4.2s transcribe=0.4s total=0.5s | compute=0.4s 10.5x realtime | peak GPU 2.5GB
```

`transcribe` is the wait after you release the key; `compute` is total inference
time, which with streaming mostly happened while you were still speaking.
`Nx realtime` is audio seconds per second of inference — handy for comparing
models on similar clips, though it drifts with clip length and how densely
packed the speech is, so don't read too much into a single number. A cold start
after the idle unload adds `cold load=Ns`.

- **Stuck on Loading** - Whisper model downloading for the first time (requires internet).
- **Recording but no text** - Microphone permission not granted.
- **Recording won't stop / pill stuck** - press Escape; the daemon force-resets and stays usable.
- **"Needs Accessibility permission" after reinstalling** - the build wasn't signed with the local certificate (see Development), so macOS voided the grant. Remove Open Whisper from System Settings > Privacy & Security > Accessibility and re-add it, then run `make signing-cert` so it doesn't happen again.
- **First dictation after hours idle feels slow** - that's the model rewarming (status shows "waking speech model"); it loads while you speak.

Run non-interactive startup checks (config, permissions, key imports):
```bash
python daemon.py --check
```

## Development

One-time setup per machine:

```bash
./setup.sh            # venv + dependencies + overlay binary
make signing-cert     # local code-signing certificate (see below)
```

Iterate and release:

```bash
make test                       # recording-lifecycle and streaming tests
.venv/bin/python3 menubar.py    # run from source
make app                        # build dist/Open Whisper.app (py2app, signed)
make install                    # copy to /Applications (sudo)
```

### Code signing

macOS ties Accessibility grants to the app's code signature, and unsigned builds get a new throwaway signature every time - so without signing, every reinstall voids the permission. `make signing-cert` creates a free self-signed certificate ("Open Whisper Dev") in the Mac's login Keychain, and `build_app.sh` signs every build with it, so rebuilds keep their permissions. The certificate is per-machine: after cloning the repo on a new Mac, run `make signing-cert` once and grant permissions once. It has no authority beyond the Mac it was created on - this app is not distributable to other people's machines without proper Apple notarisation.

## Project Structure

```
open-whisper/
├── daemon.py                    # Core daemon: recording, transcription, typing
├── menubar.py                   # Menu bar UI (rumps) + daemon supervisor
├── paths.py                     # State/log/resource path helpers
├── overlay.swift                # Floating Liquid Glass overlay (SwiftUI)
├── assets/                      # App icon (.icns + source PNG)
├── SVG icons for menu bar/      # Menu bar template icons
├── scripts/create-signing-cert.sh  # Per-machine signing certificate setup
├── tests/test_recovery.py       # Lifecycle recovery + streaming tests
├── config.example.yaml          # Template config, seeded on first run
├── setup.sh                     # Dev setup (venv + overlay)
├── build_app.sh / setup.py      # py2app build + signing
├── create_icon.py               # Regenerate assets/AppIcon.icns (needs pillow)
└── install-login-item.sh        # Legacy login-item script (menu toggle preferred)
```

Runtime state lives in `~/Library/Application Support/Open Whisper/` (config, transcript history, stats) and logs in `~/Library/Logs/Open Whisper/`.
