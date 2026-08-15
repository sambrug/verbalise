# Open Whisper

Local voice dictation for macOS. Hold a key, speak, release — the text appears
wherever you were typing.

Transcription runs entirely on your Mac using [WhisperKit](https://github.com/argmaxinc/WhisperKit)
and Apple's Neural Engine. No account, no API key, and nothing you dictate
leaves the device.

The app is a native Swift menu bar app, sandboxed, and lives in [`swift/`](swift/).
There is also an older Python implementation in the repo root — see
[Legacy Python implementation](#legacy-python-implementation) — which is
**deprecated** and no longer developed.

## Features

- **Hold-to-dictate anywhere.** Hold a trigger key (default Right Shift; any
  modifier or combination), speak, release. The transcript is typed into
  whatever app has focus.
- **Transcribes while you speak.** Long dictations are chunked at natural
  pauses and transcribed in the background, so the wait after release stays at
  a second or two however long you talked.
- **Three speech models.** A balanced one ships inside the app and works
  offline from first launch; a faster and a more accurate one download on
  demand, with progress and a cancel.
- **Custom vocabulary and corrections.** Bias recognition toward names,
  acronyms and jargon, and replace words it consistently mishears.
- **Cleans up after Whisper.** Silence artefacts ("thanks for watching",
  trailing ellipses, stuck-word repetition) and subtitle annotations
  (`[BLANK_AUDIO]`, `(air whooshing)`) are stripped before anything is typed.
- **Careful with your clipboard.** Short transcripts are typed as keystrokes
  and never touch it. Longer ones paste and restore what was there, and refuse
  to paste the wrong thing if the clipboard changes mid-flight.
- **Recording overlay.** A floating glass pill shows a live level meter and a
  timer while recording, and a pulse while transcribing.
- **Recovers from wedged audio.** Bounded, abandonable calls around every
  CoreAudio operation, health checks on capture, and Escape to cancel.

## Quick start

```bash
make swift-app       # build swift/build/OpenWhisperSwift.app
make swift-install   # copy it to /Applications
```

Open it, then grant the three permissions it asks for. A waveform icon appears
in the menu bar. Hold your trigger key and speak.

macOS keys permissions to an app's location, so **an app moved to
/Applications needs its grants given again** — the installer says so when it
runs.

## Requirements

- macOS 14 or later, Apple Silicon
- Three permissions, each granted separately by you:

| Permission | Why |
|---|---|
| Microphone | Records while you hold the trigger key |
| Input Monitoring | Notices the trigger key being held |
| Accessibility | Types the transcript into the app you are using |

The Permissions pane in Settings explains each one and updates live as you
grant them.

## Settings

⌘, from the menu bar icon. Five panes:

| Pane | Holds |
|---|---|
| General | Open at login, recording overlay, sounds, lifetime usage, config file, log, restart |
| Dictation | Trigger key, microphone, live input level |
| Speech Model | The three tiers with download state, and the language |
| Vocabulary | Terms to favour, and corrections |
| Permissions | The three grants, polled live |

Not every setting is in the window. Trim silence, streaming transcription and
direct typing are optimisations with no upside when switched off, so they live
in the configuration file rather than inviting people to make the app worse.

## Configuration

`~/Library/Containers/com.sambruggen.openwhisper/Data/Library/Application Support/config.json`,
reachable from Settings ▸ General ▸ Open Configuration File.

| Setting | Default | Description |
|---|---|---|
| `transcription_model` | `balanced` | `fast`, `balanced` or `accurate` |
| `trigger_key` | `shift_r` | Single key or combination, e.g. `alt_r+shift_r` |
| `language` | `en` | ISO 639-1 code, or `auto` to detect |
| `min_duration` | `0.5` | Shorter recordings are discarded (seconds) |
| `max_duration` | `300` | Auto-stops at this length (seconds) |
| `release_delay` | `0.05` | Pause after release before inserting (seconds) |
| `sample_rate` | `16000` | Audio sample rate |
| `sound_enabled` | `false` | Tone on record start and stop |
| `overlay_style` | `on` | Recording overlay: `on` or `off` |
| `vocabulary` | `[]` | Terms to bias recognition toward |
| `phonetic_corrections` | `{}` | Whole-word replacements applied after transcribing |
| `input_device` | `null` | Microphone name; `null` follows the system default |

Under `advanced:`

| Setting | Default | Description |
|---|---|---|
| `trim_silence_enabled` | `true` | Trim silence from each end before transcribing |
| `streaming_transcribe_enabled` | `true` | Transcribe in chunks while you speak |
| `model_idle_unload_minutes` | `120` | Release the model from memory after this long idle; `0` never |
| `fast_typing_enabled` | `true` | Type short transcripts instead of pasting |
| `fast_typing_max_chars` | `80` | Length threshold for the keystroke path |
| `clipboard_restore_delay` | `1.5` | Seconds before your clipboard is put back |

Trigger keys are `shift_r`, `shift_l`, `ctrl_r`, `ctrl_l`, `alt_r`, `alt_l`,
`cmd_r`, joined with `+` for a combination.

## Troubleshooting

Settings ▸ General ▸ Show Log, or
`~/Library/Containers/com.sambruggen.openwhisper/Data/Library/Logs/open-whisper-swift.log`.

- **The trigger key does nothing.** Input Monitoring is not granted, or was
  granted after the app started. Check the Permissions pane.
- **Recording, but nothing is typed.** Accessibility is not granted.
- **First dictation after hours idle feels slow.** The model unloaded and is
  reloading while you speak; the menu says so.
- **The pill will not go away.** Press Escape.

Support flags on the binary:

```bash
BIN="/Applications/Open Whisper.app/Contents/MacOS/OpenWhisperSwift"
$BIN --list-devices    # what CoreAudio can see, and the default
$BIN --warm-model      # download and load the configured model
$BIN --test-capture    # exercise the audio path with no keypress
$BIN --settings        # launch with the Settings window open
```

## Development

```bash
make swift-test        # the test suite
make swift-run         # build and launch
make swift-xcodeproj   # generate an .xcodeproj (needs xcodegen)
```

SwiftPM is the build of record and needs no Xcode. The generated Xcode project
is required only for an App Store archive, which SwiftPM cannot produce.

[`swift/README.md`](swift/README.md) is the developer detail: module layout,
the dependency seams the recovery tests use, signing, model staging and the
divergences from the Python app. [`swift/PORT_STATUS.md`](swift/PORT_STATUS.md)
records what is verified and what is not.
[`APP_STORE.md`](APP_STORE.md) covers submission.

## Legacy Python implementation

The original app — `daemon.py`, `menubar.py`, `overlay.swift` and the py2app
build at the repo root — is **deprecated**. It still runs, and `make test`,
`make app` and `make install` still build it, but it receives no further work
and the Swift app supersedes it in every respect.

It stays in the tree for two reasons. `swift/Scripts/generate-fixtures.py` runs
the real `daemon.py` to produce the fixtures that prove the port's text
pipeline matches the original's output line for line; delete it and those can
never be regenerated. And it is the reference for behaviour the Swift port
deliberately changed, which `swift/README.md` lists.

It cannot go to the App Store — py2app bundles are not submittable, which is
what prompted the port.

Do not run both at once. They use separate bundle IDs and settings, but they
listen for the same trigger key, so both would record and both would type.
