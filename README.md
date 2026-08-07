# Open Whisper

Local SuperWhisper-like voice dictation for macOS. Hold a key to speak, release to have text appear at your cursor.

Runs entirely on-device using MLX Whisper on Apple Silicon GPU. No API keys, no network calls after the one-time model download.

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

Hold the trigger key: audio records and a floating pill shows a live waveform. While you're still speaking, long dictations are transcribed in the background chunk by chunk at natural pauses (streaming transcribe), so the wait after release stays short no matter how long you talk. On release, the last chunk is transcribed, trailing hallucinations ("thanks for watching", stray ellipses) are stripped, phonetic corrections are applied, and the text is typed at your cursor - short text as direct keystrokes, long text via a clipboard paste that restores your previous clipboard afterwards.

## Menu Options

- **Status** - current state, including the trigger key when ready
- **Last transcription** - click to copy to clipboard
- **Recent Transcripts** - last 10 transcripts, click any to copy
- **Restart** - restart the daemon
- **Fast / Balanced / Quality** - presets that swap the Whisper model
- **Trigger Key** - single key or combo (e.g. Right Option + Right Shift)
- **Advanced** - transcription model picker, input device, vocabulary, phonetic corrections, toggles, stats
- **Quit Open Whisper**

Menu changes auto-restart the daemon.

## Configuration

Config lives at `~/Library/Application Support/Open Whisper/config.yaml` (open it via Advanced > Open Config). Most settings are also in the menu.

| Setting | Default | Description |
|---------|---------|-------------|
| `transcription_model` | `turbo` | Whisper model: `tiny`, `base`, `small`, `distil-medium`, `medium`, `distil-large`, `turbo`, `large` |
| `trigger_key` | `shift_r` | Single key or combo, e.g. `alt_r+shift_r` |
| `language` | `en` | Transcription language (ISO 639-1) |
| `min_duration` | `0.5` | Minimum recording length (seconds) |
| `max_duration` | `300` | Maximum recording length - auto-stops at this limit (seconds) |
| `release_delay` | `0.05` | Pause after key release before pasting (seconds) |
| `sample_rate` | `16000` | Audio sample rate |
| `sound_enabled` | `false` | Audio feedback on record start/stop |
| `overlay_enabled` | `true` | Show floating Liquid Glass overlay while recording/processing |
| `overlay_translucent` | `true` | Translucent (Liquid Glass) overlay vs solid capsule |
| `vocabulary` | `[]` | Domain terms (acronyms, names) to bias Whisper recognition |
| `phonetic_corrections` | `{}` | Whole-word replacements applied after transcription (e.g. `ethanol: FNOL`) |
| `input_device` | `null` | Audio input device name; `null` uses system default |

### Advanced

Under `advanced:` in `config.yaml`:

| Setting | Default | Description |
|---------|---------|-------------|
| `trim_silence_enabled` | `true` | Trims leading/trailing silence before transcription |
| `streaming_transcribe_enabled` | `true` | Transcribes audio in chunks at silence gaps while you speak, so post-release latency stays flat |
| `fast_typing_enabled` | `true` | Inject short transcripts via Quartz unicode events instead of clipboard paste |
| `fast_typing_max_chars` | `80` | Length threshold for the unicode-event typing path |
| `clipboard_restore_delay` | `1.5` | Seconds the dictation stays on the clipboard after a paste before your previous clipboard is restored. Raise it if a slow app still pastes your old clipboard; set `0` to never restore |

## Trigger Keys

Single keys: `shift_r`, `shift_l`, `ctrl_r`, `ctrl_l`, `alt_r`, `alt_l`, `cmd_r`

Combos - join with `+`:
```yaml
trigger_key: alt_r+shift_r   # Right Option + Right Shift
```

## Floating Overlay (Liquid Glass)

A floating pill appears at the bottom of the screen while recording and processing. Recording shows a live waveform with a `0:05`-style timer; processing shows a sine-pulse. Disable via the **Overlay** toggle in Advanced; switch to a solid variant via **Translucent Overlay**.

The overlay is built from `overlay.swift` and compiled by `setup.sh` (requires Xcode Command Line Tools: `xcode-select --install`).

## Logs & Troubleshooting

Logs are written to `~/Library/Logs/Open Whisper/daemon.log`. Use **View Logs** in the menu to tail them live.

```
[14:32:01] Recording...
[14:32:05] Transcribing 4.2s | whisper=turbo
[14:32:05] Raw (14w): I was thinking we should look at the login page
[14:32:06] Done: record=4.2s transcribe=1.1s total=1.2s
```

- **Stuck on Loading** - Whisper model downloading for the first time (requires internet).
- **Recording but no text** - Microphone permission not granted. Check System Settings > Privacy & Security > Microphone.
- **Recording won't stop / pill stuck** - press Escape; the daemon force-resets and stays usable.

Run non-interactive startup checks (config, permissions, key imports):
```bash
python daemon.py --check
```

## Development

```bash
./setup.sh                 # venv + dependencies + overlay binary
make test                  # recording-lifecycle and streaming tests
.venv/bin/python3 menubar.py   # run from source
make app                   # build dist/Open Whisper.app (py2app, self-contained)
make install               # copy it to /Applications (sudo)
./install-login-item.sh    # start automatically on login
```

## Project Structure

```
open-whisper/
├── daemon.py               # Core daemon: recording, transcription, typing
├── menubar.py              # Menu bar UI (rumps) + daemon supervisor
├── paths.py                # State/log/resource path helpers
├── overlay.swift           # Floating Liquid Glass overlay (SwiftUI)
├── assets/                 # App icon (.icns + source PNG)
├── SVG icons for menu bar/ # Menu bar template icons
├── tests/test_recovery.py  # Lifecycle recovery + streaming tests
├── config.example.yaml     # Template config, seeded on first run
├── setup.sh                # Dev setup (venv + overlay)
├── build_app.sh / setup.py # py2app build
├── create_icon.py          # Regenerate assets/AppIcon.icns (needs pillow)
└── install-login-item.sh   # Register the installed app as a login item
```

Runtime state lives in `~/Library/Application Support/Open Whisper/` (config, recent transcripts, stats) and logs in `~/Library/Logs/Open Whisper/`.
