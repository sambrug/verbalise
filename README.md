# Verbalise

Hold a key, talk, let go. The text appears where you were typing.

Everything runs on your Mac. No account, no API key, and nothing you say is
sent anywhere.

Requires macOS 14 or later on Apple Silicon.

## Install

```bash
make signing-cert   # once per machine
make app
make install
```

Open it, grant the three permissions it asks for, and a waveform icon appears
in the menu bar.

The first time a speech model is used, macOS compiles it for the Neural
Engine — a one-off step that takes a few minutes per model. The menu bar icon
pulses gently while it happens, and the menu says what's going on. After that,
loads take seconds.

## Using it

Hold Right Option + Right Shift, speak, release. Escape cancels without
typing anything.

Long dictations are transcribed in chunks while you talk, so the wait after
you let go stays at a second or two however long you spoke.

The trigger key is configurable — a pair like the default, or any single
modifier such as Right Shift.

## Permissions

macOS asks for three, one at a time:

- **Microphone** — records while you hold the key
- **Input Monitoring** — notices the key being held
- **Accessibility** — types the text into the app you're in

Settings ▸ Permissions tracks all three and updates as you grant them.

Grants are tied to where the app lives, so if you move it you'll be asked
again.

## Settings

⌘, from the menu bar icon.

| Pane | |
|---|---|
| General | Login item, overlay, sounds, usage totals, config file, log |
| Dictation | Trigger key, microphone, live input level |
| Speech Model | Which model, and the language |
| Vocabulary | Terms to favour, and corrections for words it mishears |
| Permissions | The three grants |

Three models are available: Fast (Whisper Small), Balanced (Large v3 Turbo)
and Accurate (Large v3). Models download and compile in the background, and
switching to one that isn't ready yet is safe: dictation keeps using the
current model and swaps over on its own the moment the new one is ready.
Cancelling that download puts the selection back where it was.

## Configuration

Settings ▸ General ▸ Open Configuration File, or:

```
~/Library/Containers/com.sambruggen.verbalise/Data/Library/Application Support/config.json
```

| Setting | Default | |
|---|---|---|
| `transcription_model` | `balanced` | `fast`, `balanced` or `accurate` |
| `trigger_key` | `alt_r+shift_r` | Single key or combination, e.g. `shift_r` |
| `language` | `en` | ISO 639-1 code, or `auto` |
| `min_duration` | `0.5` | Shorter recordings are discarded |
| `max_duration` | `300` | Auto-stops at this length |
| `release_delay` | `0.05` | Pause after release before inserting |
| `sample_rate` | `16000` | |
| `sound_enabled` | `false` | Tone on start and stop |
| `overlay_style` | `on` | `on` or `off` |
| `vocabulary` | `[]` | Terms to bias recognition toward |
| `phonetic_corrections` | `{}` | Whole-word replacements applied after transcribing |
| `input_device` | `null` | Microphone name; `null` follows the system default |

Under `advanced:`

| Setting | Default | |
|---|---|---|
| `trim_silence_enabled` | `true` | Trim silence from each end |
| `streaming_transcribe_enabled` | `true` | Transcribe in chunks while you speak |
| `model_idle_unload_minutes` | `120` | Release the model from memory when idle; `0` never |
| `fast_typing_enabled` | `true` | Type short results instead of pasting |
| `fast_typing_max_chars` | `80` | Threshold for the keystroke path |
| `clipboard_restore_delay` | `1.5` | Seconds before your clipboard is put back |

Trigger keys: `shift_r`, `shift_l`, `ctrl_r`, `ctrl_l`, `alt_r`, `alt_l`,
`cmd_r`. Join with `+` for a combination.

## Troubleshooting

Settings ▸ General ▸ Show Log.

**The trigger key does nothing.** Input Monitoring isn't granted. Check
Settings ▸ Permissions.

**It records but nothing is typed.** Accessibility isn't granted.

**The menu bar icon is pulsing and dictation is refused.** The model in use is
still downloading or compiling. Click the status line in the menu for
details; it opens the Speech Model pane.

**The first dictation after a few hours is slow.** The model unloaded and is
reloading while you speak.

**The pill won't go away.** Press Escape.

```bash
BIN="/Applications/Verbalise.app/Contents/MacOS/Verbalise"
$BIN --list-devices    # what CoreAudio can see
$BIN --warm-model      # download and load the configured model
$BIN --test-capture    # exercise the audio path with no keypress
$BIN --settings        # launch with Settings open
```

## Development

```bash
make test        # the test suite (no Xcode required)
make run         # build and launch
make xcodeproj   # generate an .xcodeproj (needs xcodegen)
```

SwiftPM builds and tests everything without Xcode. The Xcode project is only
needed for an App Store archive.

## Licence

[MIT](LICENSE).

| | |
|---|---|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | MIT, © 2024 argmax, inc. |
| Whisper models | MIT, © OpenAI |
