# Open Whisper (Swift)

A native Swift port of the Python app in the repo root, sandboxed and App Store
compliant from the first commit. See `../swift_migration_plan.md` for the plan
this was built to and `../APP_STORE.md` for the constraints behind it.

The Python app is untouched and still works. The two coexist: different bundle
IDs, different menu bar icons, separate TCC grants.

## Build and run

```bash
make swift-test   # run the test suite
make swift-app    # build + sign swift/build/OpenWhisperSwift.app
make swift-run    # build and launch
```

Or directly:

```bash
cd swift
./Scripts/test.sh
./Scripts/build-app.sh
open build/OpenWhisperSwift.app
```

First build needs the signing identity, shared with the Python app:

```bash
./scripts/create-signing-cert.sh   # from the repo root, once per machine
```

## Why SwiftPM rather than an .xcodeproj

This was built on a machine with Command Line Tools only — no Xcode, no
`xcodebuild`. Nothing the app needs requires it: swiftc, the bundle layout,
`codesign`, and Swift Testing are all CLT tools. So SwiftPM plus
`Scripts/build-app.sh` (which assembles `Contents/` and signs with the
entitlements) is the build of record, and it is what every commit is tested
against.

`project.yml` generates an equivalent `.xcodeproj` for anyone who prefers the
IDE:

```bash
brew install xcodegen
make swift-xcodeproj
```

The `.xcodeproj` is gitignored — regenerate it, don't edit it. Sources,
entitlements, `Info.plist` and the WhisperKit pin are shared with the SwiftPM
build, so the two cannot drift on anything that matters.

`Scripts/test.sh` asks `xcode-select -p` which toolchain is active and adapts:
under CLT it points the compiler at the CLT `Testing.framework` and disables the
Foundation cross-import overlay (the CLT ships that overlay's binary but not its
`.swiftmodule`, so any file importing both `Testing` and `Foundation` otherwise
fails to compile). Under Xcode it does neither, since Xcode ships a complete
Swift Testing.

## Layout

| Module | Contains |
|---|---|
| `Sources/OpenWhisperCore` | All logic and the injectable seams. No WhisperKit, no AppKit UI. This is what the tests build against, so it stays fast to compile. |
| `Sources/OpenWhisperSpeech` | The WhisperKit adapter, isolated so the heavy dependency stays out of the test cycle. |
| `Sources/OpenWhisperSwift` | The app: menu, pill, windows, key tap, wiring. |

The dependency seams in `Seams.swift` exist because the recovery tests drive the
real state machine with fakes — wedged streams, refusing clipboards,
transcribers that finish after a dictation was abandoned. That is what makes the
failure modes testable without a microphone.

## Signing and the sandbox

The app is sandboxed from the first build, with exactly three entitlements
(`Resources/OpenWhisperSwift.entitlements`): app sandbox, audio input, and
network client for model downloads. There is no entitlement for `CGEventTap` or
`CGEvent.post` — those are runtime TCC grants.

Builds are signed with the local `Open Whisper Dev` identity. TCC ties grants to
the code signature, so this is what stops every rebuild costing you the Input
Monitoring and Accessibility grants again.

**Verified on this machine:** a sandboxed build can both observe the trigger key
and synthesise keystrokes into another app, and WhisperKit downloads and loads
models inside the container with only `network.client`.

## Speech models

Three tiers rather than the Python's eight keys — see the commit message on
`ec86c0d` for why. All eight old key names still decode onto the nearest tier,
so existing configs keep working.

| Tier | WhisperKit model | Size |
|---|---|---|
| `fast` | `openai_whisper-small_216MB` | ~216 MB |
| `balanced` (default, bundled) | `openai_whisper-large-v3_turbo_954MB` | ~954 MB |
| `accurate` | `openai_whisper-large-v3` | ~3 GB |

Only `balanced` ships inside the app; the others download on demand. Development
builds skip the staging step entirely and download on first use, which keeps the
rebuild loop fast. Before a release or App Store archive:

```bash
./Scripts/fetch-default-model.sh   # stages the bundled model into Resources/
./Scripts/build-app.sh             # folds it into the bundle
```

`Resources/Models/` is gitignored. The script refuses to start below 5 GB free —
a download that runs out of space leaves a partial model behind.

## Support flags

```bash
BIN=build/OpenWhisperSwift.app/Contents/MacOS/OpenWhisperSwift

$BIN --list-devices                    # what CoreAudio can see, and the default
$BIN --warm-model                      # download + load the configured model
$BIN --test-capture --prewarm-first    # exercise the audio path, no keypress
```

`--list-devices` answers the first question when a configured microphone stops
working. `--test-capture` exists because a crash in the audio path leaves a
report with no exception message; a reproducer that prints its own failure beats
reading code.

## Where state lives

Everything is in the app container, nothing outside it:

```
~/Library/Containers/com.sambruggen.openwhisper/Data/Library/
  Application Support/config.json                 # settings (JSON, hand-editable)
  Application Support/api-usage.json              # lifetime counters
  Application Support/recent-transcripts.json     # last 10
  Application Support/Models/                     # downloaded models
  Logs/open-whisper-swift.log
```

The stats files keep the Python's filenames, keys and timestamp format, so
*Import from Open Whisper (Python)…* is a file copy rather than a translation.

## Divergences from the Python app

Beyond plan §10's accepted list:

- **Three model tiers**, not eight keys (above).
- **Overlay is on or off.** The opaque `solid` capsule was a fallback for macOS
  without Liquid Glass; with a macOS 14 floor it is a worse-looking duplicate.
  Old configs naming `solid` or `translucent` load as on.
- **Config is JSON**, not YAML (plan §10 permits this). Same keys, same
  defaults.
- **Phonetic corrections apply in sorted-key order.** Python uses dict insertion
  order, which a Swift `Dictionary` cannot preserve through decoding; sorting is
  deterministic rather than hash-dependent. Only observable when two rules
  overlap.
- **No English-only clamp.** The Python forced `en` for its distil models
  because they were English-only builds; no tier here is.
