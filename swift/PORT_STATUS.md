# Swift port — status and resume point

Working notes for the port described in `../swift_migration_plan.md`.
Updated at each phase boundary so an interrupted session can be picked up
without re-deriving anything. Branch: `swift-port`.

## How to resume

```bash
cd swift
./Scripts/test.sh          # run the suite
./Scripts/build-app.sh     # build + sign build/OpenWhisperSwift.app
open build/OpenWhisperSwift.app
tail -f ~/Library/Containers/com.sambruggen.openwhisper/Data/Library/Logs/open-whisper-swift.log
```

Every phase ends in a green suite and its own commit, so `git log --oneline`
on this branch is the progress record. If the tree is dirty, the phase in
"In progress" below is the one that was underway.

## Toolchain deviation from the plan

The plan (§2, §8, §11) assumes Xcode 26 and drives everything through
`xcodebuild`. **This machine has Command Line Tools only — there is no
Xcode and no `xcodebuild`.** Nothing the app needs requires it:

| Need | Plan's tool | Used instead |
|---|---|---|
| Compile | `xcodebuild` | `swift build` (SwiftPM) |
| Test | `xcodebuild test` | `swift test` via `Scripts/test.sh` |
| App bundle | Xcode packaging | `Scripts/build-app.sh` assembles `Contents/` |
| Sandbox + entitlements | Xcode signing | `codesign --entitlements` |

Swift Testing ships inside the CLT but outside the default search path, so
`Scripts/test.sh` passes `-F /Library/Developer/CommandLineTools/Library/Developer/Frameworks`.
With Xcode installed that directory is absent and the flags are skipped.

**Xcode is being installed** (as of 2026-08-14), which relaxes this. Once it
lands:

```bash
sudo xcode-select -s /Applications/Xcode.app   # needs Sam's password
```

`Scripts/test.sh` already handles both worlds — it asks `xcode-select -p`
which toolchain is *active* and only applies the CLT workarounds when the CLT
is the one in charge. Nothing needs changing to switch over.

**Keep SwiftPM as the build of record even then.** It is what every commit
here is tested against, and it works without Xcode at all — useful for CI and
for a fresh machine. The `.xcodeproj` is an additional entry point, not a
replacement: Phase 6 adds `project.yml` so `xcodegen` can generate one for
anyone who prefers to work in the IDE.

## Resolved plan gaps

- **§4 / §7 WhisperKit package.** `argmaxinc/argmax-oss-swift` and
  `argmaxinc/WhisperKit` are the *same repository* — identical tags and
  commit SHAs. Latest release is **v1.1.0**; pin that.

## Phase status

| Phase | State | Gate |
|---|---|---|
| 1. Scaffold + sandbox proof | **Done + verified** (`f258e48`) | Builds, signs sandboxed, runs. Both TCC-gated behaviours confirmed working — see below. |
| 2. Pure logic + fixture tests | **Done** (`309f7ed`..`5eca2ed`) | 52 tests green, incl. 122 differential cases vs Python |
| 3. State machine + recovery tests | **Done** (`e11af6a`..`HEAD`) | 104 tests green; all 11 scenario groups ported |
| 4. Real adapters | **Built, gate pending** | End-to-end dictation into TextEdit — needs a human to speak |
| 5. Product UI | **Built** | Manual checklist, plan §11 — **outstanding** |
| 6. Polish + handover | **Done** | — |

All six phases are implemented. What remains is verification, not code: the
plan §11 checklist below has only been partly exercised.

## After the plan

**Settings moved into a window** (2026-08-14), which the plan did not call for.
Five panes in a System Settings-style sidebar — General, Dictation, Speech
Model, Vocabulary, Permissions — replacing the menu's `Settings ▸` submenu and
absorbing the onboarding window as its Permissions pane. Built to a mockup Sam
approved first, then narrowed from seven panes to five once it was clear three
of them held four controls between them.

The pieces worth knowing:

| File | Holds |
|---|---|
| `OpenWhisperCore/ModelCatalog.swift` | The Speech model list's state table. Pure, 15 tests. |
| `OpenWhisperCore/PhoneticText.swift` | The two editable text formats, 11 tests. |
| `OpenWhisperSpeech/ModelDownloader.swift` | Downloads a tier without switching to it. Cancellable. |
| `OpenWhisperSwift/SettingsWindow.swift` | The window, the panes enum, the bridge to the app. |
| `OpenWhisperSwift/SettingsPanes.swift` | The SwiftUI views. |
| `OpenWhisperSwift/InputPreview.swift` | Opens the mic for the level meter, and never during a dictation. |
| `OpenWhisperCore/Language.swift` | The language picker's list, and what "Automatic" means. |

`OnboardingWindow.swift` and `TextEditorWindow` are **deleted** — both were
replaced by panes. `PythonImport.swift` is **deleted** too: Sam dropped the
feature (2026-08-14) rather than finish verifying it, so plan §9 phase 6's
import action no longer exists. It is in the history if it is ever wanted.

The lifetime counters moved out of the menu into Settings ▸ General as three
labelled rows. `StatsFormatter.formatStats` is the single-line menu form and is
now unused by the app, kept because the fixture suite verifies it against the
Python's output and that parity is worth not losing. SwiftUI rather than AppKit here (the second place after the
pill): the grouped-inset list and the sidebar are stock controls in SwiftUI and
hand-built ones in AppKit, and matching macOS is the whole point of the window.

**Download and selection are deliberately separate.** A tier can be fetched
while dictation carries on with the current one, and a fetch can be cancelled.
`ModelCatalog` merges two sources of "downloading" — explicit fetches from the
window, and the implicit one the engine starts when the configured model is
missing — so a model fetched on the way to a dictation appears in the list as a
download rather than as simply missing.

```bash
./build/OpenWhisperSwift.app/Contents/MacOS/OpenWhisperSwift --settings
```

## Outstanding

Two items, both recorded against the plan's own §11 checklist:

1. **Yank a Bluetooth mic mid-recording.** The recovery machinery has coverage
   against fakes for all 11 scenario groups and none against real hardware.
2. **Click through the Settings window.** New as of 2026-08-14. Specifically:
   a model downloading with visible progress and a working Cancel, and the
   Permissions pane ticking over live as a grant is made in System Settings.

Everything else on §11 is ticked.

## Original checklist (superseded by §11 in the plan)

Verified so far — sandbox event taps and keystroke posting, end-to-end
dictation, the pill, the editors' clipboard shortcuts.

Not yet checked by a human:

- [ ] A long dictation (>30s) streams; release-to-text wait stays short
- [ ] Short dictation leaves the clipboard untouched; long one restores the
      previous clipboard after ~1.5s
- [ ] Escape cancels a live recording; nothing is typed
- [ ] Switching models downloads with visible progress and works after
- [ ] **Yank a Bluetooth mic mid-recording** — the recovery machinery has 11
      scenario groups of coverage against *fakes* and none against real
      hardware. This is the most valuable unchecked item.
- [ ] Launch at Login survives a logout/login
- [ ] Onboarding window (only visible via *Permissions…* while grants are in
      place)

### What Phase 2 landed

`TextPipeline`, `Silence`, `Stats`, `Settings` in `Sources/OpenWhisperCore/`.
The text pipeline and stats are verified *differentially* against the Python:
`Scripts/generate-fixtures.py` runs the real `daemon.py` functions over a
corpus and records what they produce into
`Tests/OpenWhisperCoreTests/Fixtures/text-pipeline.json`; the Swift tests
assert equality. Regenerate after any change to the Python pipeline:

```bash
.venv/bin/python3 swift/Scripts/generate-fixtures.py
```

Two divergences worth knowing, both deliberate and commented in the source:

- **Phonetic corrections apply in sorted-key order**, not config-file order.
  Python uses dict insertion order, which a Swift `Dictionary` cannot preserve
  through decoding. Only observable when two rules overlap.
- **Config is JSON, not YAML** (plan §10 permits this). Keys and defaults are
  unchanged, so a Python config maps across one-to-one.

### What Phase 3 landed

All eleven scenario groups from `tests/test_recovery.py`, with the seams the
plan's §3 calls for (`Seams.swift`): audio stream/opener, monotonic clock,
pasteboard, keyboard poster, transcriber.

| Component | Covers |
|---|---|
| `Bounded` | the timeout primitive every audio call goes through |
| `AudioSession` | groups 1-3 — wedged teardown, blocked open, orphan close, escalation |
| `DictationController` | groups 4-8 — escape, capture health, leaked timer, abandonment, normal path |
| `TextInserter` | group 9 — refused write, hijack, restore window |
| `StreamingTranscriber` | group 10 — feed ordering, failure fallback |
| `ModelLifecycle` | group 11 — idle unload |

**The central invariant is the generation counter** in `DictationController`.
Every dictation gets a number and every async continuation captures the number
it started under; anything finishing after its generation moved on is
discarded. That is what stops a slow transcription typing into whatever the
user did next. It is verified by mutation: disabling the guard fails exactly
the two abandonment tests and nothing else.

### What Phase 4 landed

WhisperKit 1.1.0 (pinned exactly), `AVAudioEngine` capture, CoreAudio device
enumeration, the settings store, the pasteboard adapter, and the app wiring.

**The sandbox question is answered.** WhisperKit downloads *and* loads under
App Sandbox with only `network.client`, storing in the container — verified by
running the signed bundle with `--warm-model` to completion, zero denials.

**Model choice diverges from plan §4 on purpose.** Three tiers
(fast/balanced/accurate) instead of the Python's eight keys; see the commit
message on `ec86c0d` for why. `balanced` ships in the bundle, the other two
download on demand. All eight legacy key names still decode onto the nearest
tier, so existing configs keep working.

Two support flags on the binary, useful when something misbehaves:

```bash
./build/OpenWhisperSwift.app/Contents/MacOS/OpenWhisperSwift --list-devices
./build/OpenWhisperSwift.app/Contents/MacOS/OpenWhisperSwift --warm-model
```

**Watch the disk.** The full-precision `accurate` tier is ~3 GB, and a download
that runs out of space leaves a partial model behind. `fetch-default-model.sh`
refuses to start below 5 GB free for that reason.

### Phase 4 starting notes (done — kept for reference)

- Pin WhisperKit **v1.1.0** (see resolved gaps above) and add it to
  `Package.swift` as a package dependency. This is the first step needing
  network access.
- The adapters to write are the real implementations of the `Seams.swift`
  protocols, plus `KeyMonitor` (extend `Sources/OpenWhisperSwift/KeyTap.swift`,
  which already handles tap creation, per-keycode matching, and re-enable).
- `AudioSession` already expects `AudioStream` methods to block; the
  `AVAudioEngine` implementation should not try to hide that.
- Plan §7 wants the model-name mapping resolved at build time and any key
  without a WhisperKit equivalent greyed out rather than silently missing.

## Phase 1 gate: verified 2026-08-14

The APP_STORE.md §1 thesis holds. A sandboxed app can do both halves:

```
input monitoring: true, post event: true
key tap: installed for shift_r
typed test string          <- PostEvent into another app
trigger shift_r DOWN / UP  <- Input Monitoring on the trigger key
```

### Granting these on a fresh machine

Two *separate* TCC records, in two different System Settings panes. Both need
the app added by hand with the `+` button, because it lives in `swift/build/`
rather than `/Applications` (use ⌘⇧G in the file picker to type the path):

- **Privacy & Security -> Accessibility** — PostEvent, i.e. typing text.
- **Privacy & Security -> Input Monitoring** — reading the trigger key.

Then **quit and relaunch**: an already-installed event tap does not pick up a
new grant, so the running process stays deaf even after the switches flip.

Grants key on the code signature, so rebuilds do not void them even though
`build-app.sh` deletes and recreates the bundle — that is why the local
"Open Whisper Dev" identity is reused. Moving the bundle to a different path
*does* create a fresh entry, so move it before granting rather than after.

### Diagnostic worth remembering

Without the Input Monitoring grant, `CGEvent.tapCreate` still **succeeds** and
the tap installs — it simply delivers nothing. The visible symptom was a
stream of `key tap: re-enabled after disable-by-user input` lines with no
`trigger ... DOWN` ever appearing. That stopped the moment the grant landed.
So a repeating disable-by-user-input with no key events is a missing grant,
not a slow callback.
