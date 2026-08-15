# Open Whisper (Swift)

The app. Sandboxed, App Store compliant, and a port of the Python
implementation in the repo root.

`../APP_STORE.md` covers submission and the permission rules behind the
design. `../swift_migration_plan.md` is the plan this was built to.

## Build and run

```bash
make swift-test   # test suite
make swift-app    # build + sign swift/build/OpenWhisperSwift.app
make swift-run    # build and launch
```

Or from this directory: `./Scripts/test.sh`, `./Scripts/build-app.sh`.

First build needs a signing identity:

```bash
./scripts/create-signing-cert.sh   # repo root, once per machine
```

TCC ties permission grants to the code signature, so signing every build with
the same identity is what stops rebuilds costing you the Input Monitoring and
Accessibility grants.

To install it as the everyday app:

```bash
make swift-install
```

Grants are tied to the bundle path as well, so the installed copy has to be
granted again. Settings, stats and downloaded models come across untouched —
the container is keyed on the bundle ID.

## SwiftPM and Xcode

SwiftPM builds, tests and signs everything with no Xcode installed. That's the
build of record and what every commit is tested against.

`project.yml` generates an `.xcodeproj`, which you need for an App Store
archive:

```bash
brew install xcodegen
make swift-xcodeproj
```

The `.xcodeproj` is gitignored — regenerate it, don't edit it. It compiles only
the app sources and depends on this directory's package for the rest, so the
module structure and the WhisperKit pin live in `Package.swift` alone.

`Scripts/test.sh` checks `xcode-select -p` and adapts. Under Command Line
Tools it points the compiler at the CLT `Testing.framework` and disables the
Foundation cross-import overlay, whose `.swiftmodule` the CLT doesn't ship.

## Layout

| Module | |
|---|---|
| `Sources/OpenWhisperCore` | Logic and the injectable seams. No WhisperKit, no AppKit. The tests build against this. |
| `Sources/OpenWhisperSpeech` | The WhisperKit adapter. |
| `Sources/OpenWhisperSwift` | Menu, settings window, pill, key tap, wiring. |

The seams in `Seams.swift` let the recovery tests drive the real state machine
with fakes: wedged streams, refusing clipboards, transcribers that finish after
a dictation was abandoned.

## Sandbox

Three entitlements, in `Resources/OpenWhisperSwift.entitlements`: app sandbox,
audio input, network client. `CGEventTap` and `CGEvent.post` need no
entitlement — they're runtime TCC grants.

Confirmed working on this machine: a sandboxed build observes the trigger key
and synthesises keystrokes into other apps, and WhisperKit downloads and loads
models inside the container with only `network.client`.

## Speech models

| Tier | WhisperKit model | Size |
|---|---|---|
| `fast` | `openai_whisper-small_216MB` | ~216 MB |
| `balanced` (default, bundled) | `openai_whisper-large-v3_turbo_954MB` | ~954 MB |
| `accurate` | `openai_whisper-large-v3` | ~3.0 GB |

The Python's eight model keys all decode onto the nearest tier, so old configs
keep working.

Downloading is separate from selecting, so a tier can be fetched in the
background while dictation carries on with the current one.

Development builds skip the bundled model and download on first use. Before a
release:

```bash
./Scripts/fetch-default-model.sh   # stages the model into Resources/
./Scripts/build-app.sh             # folds it into the bundle
```

`Resources/Models/` is gitignored. The script needs 5 GB free.

## Support flags

```bash
BIN=build/OpenWhisperSwift.app/Contents/MacOS/OpenWhisperSwift

$BIN --list-devices                    # what CoreAudio can see, and the default
$BIN --warm-model                      # download + load the configured model
$BIN --test-capture --prewarm-first    # exercise the audio path, no keypress
$BIN --settings                        # launch with the Settings window open
```

## Where state lives

```
~/Library/Containers/com.sambruggen.openwhisper/Data/Library/
  Application Support/config.json                 # settings
  Application Support/api-usage.json              # lifetime counters
  Application Support/recent-transcripts.json     # last 10
  Application Support/Models/                     # downloaded models
  Logs/open-whisper-swift.log
```

The stats files keep the Python's filenames, keys and timestamp format, so
copying those two JSON files across by hand works.

## Differences from the Python app

- Three model tiers instead of eight keys. WhisperKit's Core ML builds don't
  map one-to-one, and `distil-medium.en` isn't published at all.
- Settings are a window, not the menu. The onboarding window folded into it as
  the Permissions pane.
- Trim silence, streaming transcription and direct typing aren't in the UI.
  They're honoured, and editable in the config file.
- Whisper's subtitle annotations (`[BLANK_AUDIO]`, `(air whooshing)`) are
  stripped. `stripNonSpeechAnnotations` handles them, kept separate from
  `cleanHallucinations` so that function stays byte-comparable with the Python.
- No import from the Python app. It was built, never verified end to end, and
  dropped.
- Overlay is on or off. The opaque `solid` style was a fallback for macOS
  without Liquid Glass. Old configs naming `solid` or `translucent` load as on.
- The pill isn't a verbatim port any more. The solid variant is gone, the glass
  gained a shadow, and levels are sampled at a fixed 20Hz rather than pushed
  once per audio buffer. `overlay.swift` in the repo root still drives the
  Python app, so the two render differently now.
- Config is JSON, not YAML. Same keys, same defaults.
- Phonetic corrections apply in sorted-key order. Python uses dict insertion
  order, which a Swift `Dictionary` can't preserve through decoding.
- No English-only clamp. The Python forced `en` for its distil models; no tier
  here is English-only.
