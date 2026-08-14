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

To use it as the everyday app rather than a build in a folder:

```bash
make swift-install   # from the repo root, copies to /Applications
```

That is not just a copy. TCC keys Input Monitoring and Accessibility to the
bundle **path**, so the installed copy is a different app to macOS and both
grants have to be given again. Settings, stats and downloaded models do come
across untouched — the container is keyed on the bundle ID, not the location.
The target refuses to overwrite the Python app, which installs under the same
name.

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
| `accurate` | `openai_whisper-large-v3` | ~3.0 GB |

Only `balanced` ships inside the app; the others download on demand. Settings ▸
Speech model shows all three at once with their real state — in use, ready,
downloading with progress, or not downloaded — and downloading is separate from
selecting, so a tier can be fetched in the background while dictation carries
on with the current one. Development
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
$BIN --settings                        # launch with the Settings window open
```

`--list-devices` answers the first question when a configured microphone stops
working. `--test-capture` exists because a crash in the audio path leaves a
report with no exception message; a reproducer that prints its own failure beats
reading code. `--settings` exists because a menu bar app's Settings window is
otherwise a menu-bar hover away, which no script can do.

## The Settings window

Configuration lives in a window (⌘, from the menu), not in the menu itself —
five panes in a sidebar, matching System Settings: General, Dictation, Speech
Model, Vocabulary, Permissions. The Python app put every
setting in the menu bar, which meant nothing could show progress, the permission
rows needed a second window of their own, and each toggle was a four-level
hover.

The status menu is now only what you act on in the moment: state, the last
transcript, Recent, Settings…, the lifetime counters, Restart, Quit.

`ModelCatalog` (in `OpenWhisperCore`) derives the Speech model list from four
independent signals — selected, on disk, downloading, progress known. It is pure
and tested apart from the window, because the combinations that matter are the
ones a screenshot never shows you: a model selected while it is still
downloading must not claim to be in use.

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

The stats files keep the Python's filenames, keys and timestamp format. There
is no longer an import action — it was dropped before it was ever verified
end to end — but the formats still line up, so copying the two JSON files
across by hand works.

## Divergences from the Python app

Beyond plan §10's accepted list:

- **Three model tiers**, not eight keys (above).
- **Overlay is on or off.** The opaque `solid` capsule was a fallback for macOS
  without Liquid Glass; with a macOS 14 floor it is a worse-looking duplicate.
  Old configs naming `solid` or `translucent` load as on.
- **The pill is no longer a verbatim port.** Plan §1 put its look off-limits
  for redesign, and that held through the initial port — but the solid variant
  has since been removed, the glass moved from `.regular` to `.clear`, and the
  level feed rewritten to sample at a fixed rate. Those were deliberate
  decisions taken after seeing it run, not drift, but the "unchanged
  rendering" guarantee in §1 no longer holds. `overlay.swift` at the repo root
  is unmodified and still drives the Python app, so the two now render
  differently.
- **Levels are sampled, not pushed.** The Python fed the pill one level per
  audio buffer; here a `LevelMeter` decouples the audio thread from the
  animation, which samples at a fixed 20Hz. Buffer arrival is neither regular
  nor a rate the animation should inherit.
- **Settings live in a window, not the menu** (above). This also absorbed the
  separate onboarding window: the permission rows are now a pane, and the
  lifetime counters are rows in General.
- **No import from the Python app.** Plan §9 phase 6 called for one and it was
  built; it was dropped before being verified. The stats file formats still
  match, so a hand copy works.
- **Not every setting is in the window.** Trim silence, streaming
  transcription and direct typing are optimisations with no upside when off,
  so surfacing them invited people to make the app worse. They are honoured,
  and editable in the configuration file.
- **Whisper's subtitle annotations are stripped.** It writes `[BLANK_AUDIO]`
  for silence and describes sounds it hears (`(air whooshing)`) because it was
  trained on caption data. `stripNonSpeechAnnotations` removes them; the
  Python never did. Kept out of `cleanHallucinations` so that function stays
  byte-comparable with the Python.
- **Config is JSON**, not YAML (plan §10 permits this). Same keys, same
  defaults.
- **Phonetic corrections apply in sorted-key order.** Python uses dict insertion
  order, which a Swift `Dictionary` cannot preserve through decoding; sorting is
  deterministic rather than hash-dependent. Only observable when two rules
  overlap.
- **No English-only clamp.** The Python forced `en` for its distil models
  because they were English-only builds; no tier here is.
