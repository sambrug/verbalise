# Open Whisper

Local SuperWhisper-like voice dictation for macOS. Hold a key to speak, release to have text appear at your cursor.

Runs entirely on-device using MLX Whisper on Apple Silicon GPU. Optionally cleans up text using a local LLM via Ollama, or an API model (Claude Haiku by default).

## Quick Start

1. Double-click `Open Whisper.app`
2. Grant **Accessibility** and **Microphone** permissions when prompted
3. A mic icon appears in your menu bar
4. Hold your trigger key and speak
5. Release - text appears at your cursor

The app auto-installs dependencies on first launch (requires Python 3.11+ and internet).

## Requirements

- macOS on Apple Silicon (M1/M2/M3/M4)
- Python 3.11+
- **Accessibility** permission (System Settings > Privacy & Security > Accessibility > add Open Whisper.app)
- **Microphone** permission (prompted on first launch)
- Optional: [Ollama](https://ollama.com) for local text cleanup
- Optional: Anthropic API key for API-based cleanup

## Cleanup Model Options

| Option | Model | Latency | Requires |
|--------|-------|---------|----------|
| Off | - | - | Nothing |
| Low | qwen2.5:1.5b | ~1s | Ollama |
| Medium | phi4-mini | ~3–4s | Ollama |
| High | gemma3:4b | ~5–6s | Ollama |
| API (default) | Claude Haiku 4.5 / Claude Sonnet 4.5 | ~1s+ | Anthropic API key |

### Ollama setup (local models)

Models are pulled automatically on first use, or manually:
```bash
ollama pull qwen2.5:1.5b    # Low preset
ollama pull phi4-mini        # Medium preset
ollama pull gemma3:4b        # High preset
```

### API cleanup setup

Use the menu's **Set API Key…** option (Advanced → Cleanup → Set API Key…) to store the key in macOS Keychain. Or set it as an environment variable:
```bash
export ANTHROPIC_API_KEY='sk-ant-...'
```

## Menu Bar Icons

| Icon | Meaning |
|------|---------|
| 🎙 Mic | Ready - hold trigger key to dictate |
| 🔴 Circle | Recording |
| ✨ Sparkle | Transcribing / cleaning up |
| ↻ Arrows | Starting up |
| 📊 Chart | Benchmarking (with % progress) |
| 🎙‍🚫 Mic slash | Stopped |
| ⚠ Warning | Error - check status text in menu |

### Troubleshooting

- **Mic slash on launch** - Accessibility permission not granted. Add Open Whisper.app in System Settings > Privacy & Security > Accessibility.
- **Stuck on Loading** - Whisper model downloading for the first time (requires internet).
- **Recording but no text** - Microphone permission not granted. Check System Settings > Privacy & Security > Microphone.
- **Warning after recording** - Check the status text in the menu for details.

## Menu Options

- **Status** - current state, including the trigger key when ready
- **Last transcription** - click to copy to clipboard
- **Recent Transcripts** - last 10 transcripts, click any to copy
- **Restart** - restart the daemon
- **Fast / Balanced / Quality** - presets that swap the Whisper model
- **Trigger Key** - single key or combo (e.g. Right Option + Right Shift)
- **Advanced** - transcription model picker, cleanup picker, input device, vocabulary, toggles, stats
- **Quit Open Whisper**

## Configuration

Edit `config.yaml` or use the menu bar. Menu changes auto-restart the daemon.

| Setting | Default | Description |
|---------|---------|-------------|
| `transcription_model` | `turbo` | Whisper model: `tiny`, `base`, `small`, `distil-medium`, `medium`, `distil-large`, `turbo`, `large` |
| `cleanup_enabled` | `false` | Enable LLM text cleanup |
| `cleanup_quality` | `low` | `low`, `medium`, `high` (Ollama) or `api` (API model) |
| `trigger_key` | `shift_r` | Single key or combo, e.g. `alt_r+shift_r` |
| `language` | `en` | Transcription language (ISO 639-1) |
| `min_duration` | `0.5` | Minimum recording length (seconds) |
| `max_duration` | `300` | Maximum recording length - auto-stops at this limit (seconds) |
| `release_delay` | `0.05` | Pause after key release before pasting (seconds) |
| `sample_rate` | `16000` | Audio sample rate |
| `sound_enabled` | `false` | Audio feedback on record start/stop |
| `overlay_enabled` | `true` | Show floating Liquid Glass overlay while recording/processing |
| `overlay_translucent` | `true` | Translucent (Liquid Glass) overlay vs solid cyan capsule |
| `vocabulary` | `[]` | Domain terms (acronyms, names) to bias Whisper recognition |
| `input_device` | `null` | Audio input device name; `null` uses system default |
| `api_model` | `claude-haiku-4-5-20251001` | Model to use for API cleanup |
| `api_input_price_per_mtok` | `1.00` | Input token price per million (update if pricing changes) |
| `api_output_price_per_mtok` | `5.00` | Output token price per million |
| `api_cleanup_prompt` | *(see config)* | System prompt for API cleanup |
| `cleanup_prompt` | *(see config)* | Few-shot prompt for local Ollama cleanup |

The Anthropic API key lives in macOS Keychain (service `open-whisper`). Set it via the menu's **Set API Key…** option.

### Advanced

Advanced settings live under `advanced:` in `config.yaml`:
```yaml
advanced:
  trim_silence_enabled: true
  cleanup_skip_heuristic_enabled: true
  benchmark_mode: false
  streaming_transcribe_enabled: false
  fast_typing_enabled: true
  fast_typing_max_chars: 80
```

| Setting | Default | Description |
|---------|---------|-------------|
| `advanced.trim_silence_enabled` | `true` | Trims leading/trailing silence before transcription |
| `advanced.cleanup_skip_heuristic_enabled` | `true` | Skips LLM cleanup for short, already-clean transcripts |
| `advanced.benchmark_mode` | `false` | Records one clip on key release and benchmarks all model/cleanup combinations |
| `advanced.streaming_transcribe_enabled` | `false` | Transcribes audio in chunks at silence gaps to reduce post-release latency |
| `advanced.fast_typing_enabled` | `true` | Inject short transcripts via Quartz unicode events instead of clipboard paste |
| `advanced.fast_typing_max_chars` | `80` | Length threshold for the unicode-event typing path |

## Floating Overlay (Liquid Glass)

A floating pill appears at the bottom of the screen while recording and processing. It uses macOS 26's Liquid Glass material so it reads as a proper translucent surface — recording shows live waveform with a `0:05`-style timer; processing shows a sine-pulse. Disable via the **Overlay** toggle in Advanced; switch to a solid cyan variant via **Translucent Overlay**.

The overlay is built from `overlay.swift` and compiled automatically by `setup.sh`. It requires Xcode Command Line Tools (`xcode-select --install`).

## Trigger Keys

Single keys: `shift_r`, `shift_l`, `ctrl_r`, `ctrl_l`, `alt_r`, `alt_l`, `cmd_r`

Combos - join with `+`:
```yaml
trigger_key: alt_r+shift_r   # Right Option + Right Shift
```

## Log Output

```
[14:32:01] Recording...
[14:32:05] Transcribing 4.2s | whisper=turbo cleanup=claude-haiku-4-5
[14:32:05] Raw (18w): um so basically I was thinking we should look at the login page right
[14:32:05] Cleaning up with claude-haiku-4-5-20251001...
[14:32:06] Clean (14w): I was thinking we should look at the login page.
[14:32:06] Done: record=4.2s transcribe=1.1s cleanup=0.8s total=2.0s tokens=68in/14out ~$0.0001
```

Logs are written to `daemon.log` in the project directory. Use **View Logs** in the menu to tail them live.

### Startup checks

Run a non-interactive startup validation (config, permissions, key imports, optional integrations):
```bash
python daemon.py --check
```
Returns exit code `0` on pass and `1` on failure.

## App Icon

To generate and install the app icon:
```bash
python3 create_icon.py
```
Then restart Open Whisper. If the Dock still shows the old icon: `killall Dock`

## Auto-start on Login

```bash
./install-login-item.sh
```
To remove: System Settings > General > Login Items > remove OpenWhisper.

## Project Structure

```
open-whisper/
├── Open Whisper.app/           # macOS .app bundle
│   └── Contents/
│       ├── Info.plist
│       ├── Resources/
│       │   └── AppIcon.icns    # Generated by create_icon.py
│       └── MacOS/launcher      # Compiled Swift launcher → menubar.py
├── daemon.py                   # Core daemon (recording, transcription, cleanup)
├── menubar.py                  # Menu bar UI (rumps + SF Symbols)
├── overlay.swift               # Floating Liquid Glass overlay (SwiftUI)
├── create_icon.py              # Generates and installs the app icon
├── launcher.swift              # Swift source for the .app launcher
├── config.yaml                 # User settings (gitignored)
├── config.example.yaml         # Template config (safe to commit)
├── .api-usage.json             # Lifetime API usage + word stats (gitignored)
├── .recent-transcripts.json    # Last 10 transcripts (gitignored)
├── requirements.txt            # Python dependencies
├── setup.sh                    # Manual install
├── install-login-item.sh       # Add to macOS Login Items
└── README.md
```
