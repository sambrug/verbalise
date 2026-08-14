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

To get the plan's `.xcodeproj` path back, install Xcode and run `xcodegen`
against the checked-in `project.yml` (Phase 6). The SwiftPM build remains
the one that is known to work here.

## Resolved plan gaps

- **§4 / §7 WhisperKit package.** `argmaxinc/argmax-oss-swift` and
  `argmaxinc/WhisperKit` are the *same repository* — identical tags and
  commit SHAs. Latest release is **v1.1.0**; pin that.

## Phase status

| Phase | State | Gate |
|---|---|---|
| 1. Scaffold + sandbox proof | **Done** (`f258e48`) | Builds, signs sandboxed, runs, tap installs. TCC-gated behaviours still need a human — see below. |
| 2. Pure logic + fixture tests | **Done** (`309f7ed`..`5eca2ed`) | 52 tests green, incl. 122 differential cases vs Python |
| 3. State machine + recovery tests | **Done** (`e11af6a`..`HEAD`) | 104 tests green; all 11 scenario groups ported |
| 4. Real adapters | Next | End-to-end dictation into TextEdit |
| 5. Product UI | Not started | Manual checklist, plan §11 |
| 6. Polish + handover | Not started | — |

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

### Phase 4 starting notes

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

## Outstanding: needs Sam

Phase 1's gate is not fully closed. `CGEvent.tapCreate` succeeds under the
sandbox (proven — see the log line `key tap: installed for shift_r`), but a
tap can install and still deliver nothing until Input Monitoring is granted,
so the two TCC-gated behaviours need a human to grant and exercise:

1. Grant **Input Monitoring** to `OpenWhisperSwift.app`, then hold Right
   Shift and confirm `trigger shift_r DOWN` / `UP` lines appear in the log.
2. Grant **Accessibility** (PostEvent), then use the menu's
   *Type "hello from swift"* item with a text field focused — it waits 3s so
   you can focus the target app.

Both grants are per-signature; they survive rebuilds as long as the
"Open Whisper Dev" identity is used.
