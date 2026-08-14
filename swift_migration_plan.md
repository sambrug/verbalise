# Swift migration plan

Instructions for an agent to perform a one-shot port of Open Whisper from
Python to a native Swift app, buildable in Xcode and compliant with Mac App
Store rules from the first commit. Read `APP_STORE.md` first: it is the
"why" behind every constraint here (sandbox, single process, entitlements,
WhisperKit). This document is the "what" and "how".

The Python app keeps working and is not modified. The port lives alongside
it in this repo. Feature parity with the Python app is the goal; where the
two must differ, the difference is listed in §10 and nowhere else.

---

## 1. Ground rules for the executing agent

- Do not modify, move, or delete any existing Python file, `overlay.swift`,
  `Makefile`, or build scripts. The only shared files are read-only inputs.
- All new code goes under a new `swift/` directory at the repo root.
- Commit per phase (§9), following the repo's CLAUDE.md commit hygiene:
  atomic commits, each revertable alone.
- After every phase, the build and test gates for that phase must pass
  before starting the next. Do not proceed on a red gate.
- The overlay pill's look and behaviour took a long time to get right and
  is off-limits for redesign. Port `overlay.swift` (repo root) into the app
  target with its rendering code unchanged: same states, same icons, same
  Liquid Glass default, same `--solid` capsule variant, same sizes and
  animation. Only the stdin JSON protocol is deleted (it becomes direct
  method calls in-process).
- Where this plan and the current Python behaviour disagree on a detail not
  listed in §10, the Python behaviour wins. `daemon.py` and `menubar.py`
  are the specification.

## 2. Targets, naming, toolchain

| Setting | Value | Why |
|---|---|---|
| Directory | `swift/` | Coexists with the Python app in one repo |
| Product name | `OpenWhisperSwift` | `OpenWhisperSwift.app` is unmistakable next to the Python `Open Whisper.app` in /Applications |
| Display name | Open Whisper Swift | Distinct in permission panes, Finder, and the Quit item. Renaming at App Store time costs nothing: TCC grants follow the bundle ID, not the name |
| Bundle ID | `com.sambruggen.openwhisper` | Distinct from the Python app's `com.sambruggen.open-whisper`, so TCC grants never collide. Name-agnostic on purpose: it is the permanent identity and survives the eventual rename |
| Deployment target | macOS 14.0 | WhisperKit's floor (APP_STORE.md §3) |
| Swift | 6 language mode, strict concurrency | Toolchain on this machine is Swift 6.3 / Xcode 26 |
| UI frameworks | AppKit `NSStatusItem` + `NSMenu` for the menu bar; SwiftUI inside windows (pill, onboarding, editors) | Dynamic submenus, badges, and marquee status text are awkward in `MenuBarExtra`; the pill is already SwiftUI |
| Tests | Swift Testing (`@Test`), one test target | |
| Project generation | XcodeGen (`brew install xcodegen`), spec checked in as `swift/project.yml` | Reviewable project definition; regenerate with `xcodegen` |
| App icon | Reuse `assets/` icon (see `create_icon.py` for how the Python one is made) | |
| `LSUIElement` | true | Menu bar accessory, no Dock icon |

If Homebrew or XcodeGen cannot be installed, hand-author the
`project.pbxproj` instead; the checked-in project must still build with
plain `xcodebuild`.

Signing for local builds: manual signing with the existing local identity
`Open Whisper Dev` (created by `scripts/create-signing-cert.sh`), so TCC
grants survive rebuilds. Sandbox is ON from the first build. App Store
signing swaps in later without code changes.

Entitlements file (complete; do not add more):

```xml
com.apple.security.app-sandbox          = true
com.apple.security.device.audio-input   = true
com.apple.security.network.client      = true   <!-- model downloads -->
```

`Info.plist` additions: `NSMicrophoneUsageDescription`, `LSUIElement`.
There is no entitlement for `CGEventTap` / `CGEvent.post`; they are runtime
TCC grants (APP_STORE.md §6).

## 3. Architecture

One process, no subprocesses, no shelling out (no `pbcopy`, `afplay`,
`osascript`, no spawned overlay). The Python app's three processes and
their plumbing (stdin pipe to the overlay, stderr/event stream to the menu
bar, supervisor restart with backoff, single-instance lock file, orphan
overlay cleanup, SIGHUP config reload) all disappear: LaunchServices
already prevents double launches, config applies live in-process, and
crash-recovery becomes watchdogs inside the process plus the existing
Restart menu item.

Suggested module layout under `swift/Sources/`:

| File / type | Responsibility | Ports |
|---|---|---|
| `App.swift`, `AppDelegate` | Lifecycle, wiring, onboarding trigger | `menubar.py` main |
| `DictationController` (actor) | The recording state machine: key held, recording, processing, cancel, force reset, watchdogs | `daemon.py` class `OpenWhisper` |
| `KeyMonitor` | `CGEventTap` for trigger combos + Escape | pynput listener |
| `AudioCapture` (actor) | `AVAudioEngine` capture at 16 kHz mono Float32, level metering, pre-warm, health check, device selection | `sounddevice` code |
| `TranscriptionEngine` (actor) | WhisperKit load/unload/transcribe, model downloads | `mlx_whisper` code |
| `StreamingTranscriber` (actor) | Chunk-at-silence fallback pipeline | `daemon.py:446` |
| `TextPipeline` (pure functions) | Hallucination cleaning, chunk joining, phonetic corrections, silence trimming/gap detection | `daemon.py:98-436` |
| `TextInserter` | Unicode-event typing + pasteboard paste with restore | `daemon.py:982-1073` |
| `Pasteboard` protocol + `NSPasteboard` impl | Verified writes, hijack detection via `changeCount` | `daemon.py:263-327` |
| `OverlayPill` | The ported pill, in-process `NSPanel` | `overlay.swift` |
| `StatusMenu` | `NSStatusItem`, menu tree, badges, marquee alert | `menubar.py` |
| `Settings` | Config model, live apply, persistence | `config.example.yaml`, `load_config` |
| `Stats` | Lifetime stats, recent transcripts, time-saved line | `daemon.py:599-648`, `menubar.py:654-693` |
| `Permissions` | Preflight/request Input Monitoring, PostEvent, mic; onboarding window | `daemon.py:1858-1927` |
| `Logging` | `os.Logger` + file log in the container's Logs dir; in-app log window | `log()` + Terminal viewer |

Dependency seams are required for the test port: `DictationController`
must take injectable audio-stream, clock, pasteboard, key-event-poster, and
transcribe dependencies, because the recovery tests drive the state machine
with fakes (wedged streams, refusing clipboards). Design for this first;
it is what makes the one-shot verifiable.

In-process event flow replaces the JSON event protocol. The daemon's
events (`daemon.py:218`, consumed at `menubar.py:1350`) become an enum
delivered to `StatusMenu` on the main actor: states `loading / ready /
recording / transcribing / stopped`, plus `warning(message)`,
`error(message)`, `permission(message)`, `configError(message)`,
`lastText(text)`, `statsChanged`.

## 4. Feature parity inventory

Everything below must exist and behave the same. Pointers are to the
Python source, which is the spec.

### Capture and lifecycle

- Hold-to-record on a trigger key or combo (`shift_r` default; combos
  joined with `+`, e.g. `alt_r+shift_r`). Key set: `shift_r, shift_l,
  ctrl_r, ctrl_l, alt_r, alt_l, cmd_r` (`daemon.py:188`). Modifiers arrive
  as `flagsChanged` events, not keyDown; track per-keycode so left/right
  distinction is exact (fixes the flag-mask limitation noted at
  `daemon.py:199`). Tap is listen-only (`kCGEventTapOptionListenOnly`).
- Handle `kCGEventTapDisabledByTimeout` / `ByUserInput` by re-enabling the
  tap. Never do slow work on the tap callback thread; start/stop hop to
  workers immediately, as the Python comments at `daemon.py:1761-1813`
  explain at length.
- Escape cancels a live recording; on a stalled stop it force-resets only
  once overdue (`_STALL_ESCAPE_THRESHOLD` behaviour, `daemon.py:1761`).
- `min_duration` 0.5 s ignore, `max_duration` 300 s auto-stop with a timer
  that must not leak into a later dictation (`daemon.py:1528`).
- Key watchdog: detect a stuck key-held state when the OS lost the release
  event (`daemon.py:773`); with a per-keycode tap this becomes a check that
  keyup was seen or the modifier flag cleared.
- Capture health check: recording but no audio delivered for a few seconds
  means reopen the input (`daemon.py:1421`).
- Wedged-device teardown: every engine stop/close is bounded by a timeout
  on a separate queue so a hung CoreAudio call can never freeze the state
  machine (`daemon.py:1268`); after a wedge, flag the audio subsystem
  suspect; a second failure escalates (`daemon.py:1250`). Escalation in
  one process means: full `AVAudioEngine` teardown and rebuild, and if that
  fails, a persistent menu alert directing the user to the Restart item.
  Subscribe to `AVAudioEngineConfigurationChange` for device/route changes.
- Force reset as the universal escape hatch (`daemon.py:1458`).
- Audio pre-warm at startup to eliminate first-keypress lag
  (`daemon.py:958`).
- Input device picker by name, System Default when unset; enumerate via
  CoreAudio (`menubar.py:633`).
- Sounds: optional Tink on start / Pop on stop (`daemon.py:248`), via
  `NSSound(contentsOfFile:)`, not `afplay`.

### Transcription

- Engine: WhisperKit (APP_STORE.md §4). Resolve the current package (the
  Argmax open-source Swift package, MIT; try
  `github.com/argmaxinc/argmax-oss-swift`, falling back to
  `github.com/argmaxinc/WhisperKit`) and pin a version. Models come from
  Argmax's CoreML model repo on Hugging Face.
- Model menu: keep today's eight keys and labels (`menubar.py:167`,
  `daemon.py:51`): tiny, base, small, distil-medium, medium, distil-large,
  turbo, large; default turbo. Map each to the closest WhisperKit model at
  build time; any key with no equivalent stays in the menu greyed out with
  a "not available" tooltip rather than silently vanishing. Distil models
  force language `en` (`daemon.py:1078`).
- Models download into the app container (never `~/.cache/huggingface`)
  with visible progress in the status item, replacing today's silent
  "Loading…" hang. Do not bundle a model in the repo; add a
  `swift/Scripts/fetch-default-model.sh` that pre-downloads the default
  model into the bundle for an App Store archive later (APP_STORE.md §5).
- Streaming: prefer WhisperKit's native streaming. Port
  `StreamingTranscriber` (`daemon.py:446`) anyway as the documented
  fallback and to preserve semantics the tests encode: feed chunks at
  silence gaps (400 ms quiet after at least 2 s of speech,
  `daemon.py:397`), strict arrival-order joining, failure falls back to
  whole-clip transcription, quiet-tail skip.
- `condition_on_previous_text = false` equivalent; vocabulary biasing via
  initial prompt in the exact format `Vocabulary: a, b.` (`daemon.py:1087`).
- Silence trimming before transcription, RMS hysteresis with padding
  (`daemon.py:328`), behind `trim_silence_enabled`.
- Idle model unload after `model_idle_unload_minutes` (default 120, 0 =
  never); reload transparently on next dictation showing "Recording…
  (waking speech model)" (`daemon.py:843-903`). Port the fixed semantics
  from commit c049892, and note WhisperKit on ANE may make this near-free;
  keep the setting regardless.
- Performance logging parity: model load time (cold vs warm) and inference
  speed per dictation (commit c778fd6). Peak GPU memory is MLX-specific;
  log what WhisperKit exposes instead.

### Text output

- Post-processing order: hallucination cleaning, then phonetic
  corrections, then insert. Port verbatim: trailing-phrase patterns and
  the loop until stable, punctuation-only rejection, repetition-loop
  detection (8+ identical words in a row, or >50% one word across 15+)
  (`daemon.py:98-163`); whole-word phonetic corrections (`daemon.py:534`);
  streaming chunk joining with boundary-period repair (`daemon.py:164`).
- Fast path: text up to `fast_typing_max_chars` (80) types directly via
  `CGEventKeyboardSetUnicodeString` in 20-char chunks, clipboard untouched
  (`daemon.py:982`). Add the small inter-chunk pacing APP_STORE.md flags
  as missing.
- Clipboard path for longer text (`daemon.py:1013`): verified write with
  retries, `release_delay` wait, re-check the pasteboard still holds our
  text immediately before posting Cmd+V (hijack detection), paste, then
  restore the user's previous clipboard after `clipboard_restore_delay`
  (1.5 s default, 0 = never) using `changeCount` so a user copy during the
  window is never clobbered. On clipboard failure or hijack: do not paste,
  keep the text in Recent Transcripts, surface the exact warning strings
  (`daemon.py:1037-1046`).
- Abandoned dictations (force reset mid-transcribe) must never type text
  later.

### Menu bar UI (`menubar.py:719-960` is the spec)

- Status line with the state labels, count badge, and the scrolling
  marquee for persistent alerts (`menubar.py:1022`).
- Last transcription (truncated smart) + Copy Last.
- Recent Transcripts submenu: last 10, timestamped labels, click to copy,
  Clear item (`menubar.py:1060`).
- Settings submenu, same order and grouping: Trigger Key picker,
  Transcription Model picker, Vocabulary editor, Phonetic Corrections
  editor, Streaming Transcribe toggle, Input Device picker, Fast Typing
  toggle, Overlay style picker (translucent / solid / off), Sound Feedback
  toggle, stats line ("N words • N recordings"), time-saved line (40 wpm
  typing vs 150 wpm speaking, same rounding, `menubar.py:672`), Open
  Config, View Logs, Restart.
- Vocabulary and phonetic-corrections editors: multiline text window with
  Save/Cancel and working Cmd+C/V/X/A (`menubar.py:374` exists because
  rumps couldn't do this; SwiftUI sheet or `NSAlert` + text view is fine).
- Launch at Login via `SMAppService.mainApp` (works sandboxed).
- View Logs opens an in-app scrolling log window tailing the file log (the
  Terminal + `osascript` route at `menubar.py:1629` is sandbox-illegal).
- Menu bar icon: deliberately different from the Python app's
  (`menubar.py:334`) so the two are tellable apart at a glance when both
  run; a plain SF Symbol (e.g. `waveform`) is fine. Swap to the shared
  branding at App Store submission time.
- Quit tears everything down cleanly (tap, engine, pill).

### Overlay pill

- Port `overlay.swift` in-process: show on record start with live level
  bars fed ~10 Hz, switch to the processing state on release, hide on
  done/cancel/error. States and icon mapping unchanged (`recording` =
  circle, `transcribing`/`cleaning` = sparkle). Styles: translucent
  (default), solid, off, from config. Rendering code verbatim.

### Config, stats, files

- Settings model mirrors `config.example.yaml` exactly: same keys, same
  defaults, including the `advanced` block. Persist as a user-editable
  file in the container's Application Support (JSON or YAML; pick one and
  keep Open Config working). Reject invalid configs with the same
  validation rules (`daemon.py:506`), surfacing `configError`.
- Settings changes apply live without restart (today: SIGHUP reload,
  `daemon.py:904`; in-process this is a direct call).
- Stats and recent transcripts: same JSON schemas as
  `daemon.py:599-648` (`total_words`, `total_recordings`; list of
  `{text, ts}` capped at 10), stored in the container.
- All state in the app container; no writes outside it (sandbox rule,
  APP_STORE.md 2.5.2).

### Permissions and onboarding

- Startup checks mirror `check_accessibility` / `check_microphone`
  (`daemon.py:1858-1927`), but with the correct APIs:
  `CGPreflightListenEventAccess` / `CGRequestListenEventAccess`,
  `CGPreflightPostEventAccess` / `CGRequestPostEventAccess`,
  `AVCaptureDevice.authorizationStatus(for: .audio)`. Never
  `AXIsProcessTrusted`.
- First-run onboarding window (required by APP_STORE.md §6): one sentence
  per permission, deep links to the exact System Settings panes, polls
  preflight and advances automatically once granted.

## 5. What is deliberately not ported

- The supervisor: daemon spawning, stderr/event watchers, auto-restart
  with backoff, exit-code protocol (`menubar.py:1301-1440`,
  `daemon.py:1246-1266`).
- Single-instance lock file, orphaned-overlay cleanup, SIGHUP handling.
- `pbcopy`/`pbpaste`, `afplay`, `osascript` shell-outs.
- `AXIsProcessTrusted` and anything AX (`APP_STORE.md` §1: sandbox-banned;
  the Python app never used AX insertion anyway).
- py2app, `build_app.sh`, `setup.py` (Python-side, untouched).

## 6. Tests first

Port `tests/test_recovery.py` to Swift Testing before implementing the
components it covers, keeping the scenario names. The fakes it defines
(WedgedStream, HealthyStream, blocked opens, FakeClipboard with
refuse/hijack modes, FakeKeyboard, ordered/raising transcribers) become
test doubles behind the §3 seams. Scenario groups to preserve, by the
file's own section headers:

1. Release with a wedged device still recovers (bounded teardown, flag
   set, captured audio still transcribed, pill hidden, next dictation
   starts).
2. A blocked open gives up instead of hanging; first strike no restart;
   already-wedged escalates; healthy open clears the flag.
3. A late-arriving stream open is closed as an orphan.
4. Escape: manual escape hatch on a stalled stop; leaves a normal
   transcription alone.
5. A device that starts but never delivers audio gets reopened; healthy
   mic does not.
6. A leaked max-duration timer never cuts a later dictation short.
7. An abandoned dictation never types text later.
8. The normal path end to end (states recording → transcribing → hidden,
   no false wedge flag).
9. Clipboard: refused writes paste nothing and preserve the user's
   clipboard; hijack before paste aborts; normal paste sends Cmd+V with
   our text present, restores the old clipboard after the delay, and a
   user copy during the window is not clobbered; short text uses the
   unicode path and never touches the clipboard.
10. Streaming: chunks join in feed order; failure falls back; chunk-join
    punctuation rules (boundary period before lowercase dropped, real
    sentence end before a capital kept, no-punctuation boundaries
    untouched).
11. Idle unload semantics.

Add pure-function tests for the text pipeline (hallucination patterns,
repetition detector, phonetic corrections, time-saved formatting) using
the Python implementations as the oracle: generate a fixture file of
input/output pairs by running the Python functions, check it in, and
assert the Swift port matches.

## 7. Model availability check

Before building the settings UI, list the models actually published in
Argmax's CoreML repo and write the mapping into a comment in
`TranscriptionEngine`. Expected good mappings: tiny, base, small, medium,
large-v3, large-v3 turbo, distil-large-v3. `distil-medium.en` may have no
equivalent; if so it is the one greyed-out menu item. Do not guess names
at runtime; fail loudly at build time.

## 8. Build and verify commands

```bash
brew install xcodegen                                  # once
cd swift && xcodegen                                   # regenerate project
xcodebuild -project OpenWhisperSwift.xcodeproj -scheme OpenWhisperSwift build
xcodebuild -project OpenWhisperSwift.xcodeproj -scheme OpenWhisperSwift test
open build/.../OpenWhisperSwift.app                    # manual runs
```

Also add a `swift-app` target to the root Makefile that wraps
generate+build, without touching existing targets.

## 9. Execution phases, each ending in a green gate and a commit

1. Scaffold and sandbox proof. Project generates and builds, sandboxed,
   signed as `Open Whisper Dev`, `LSUIElement`, empty menu bar item. A
   temporary debug menu action posts "hello from swift" into the focused
   app via `CGEvent` unicode events, and the tap logs right-shift
   down/up. This proves ListenEvent + PostEvent under sandbox on this
   machine, the whole thesis of APP_STORE.md §1. Gate: builds, runs, both
   actions work after granting the two permissions.
2. Pure logic + tests. TextPipeline, silence functions, stats formatting,
   config model and validation, with the §6 fixture tests green. Gate:
   `xcodebuild test` green.
3. State machine + recovery tests. DictationController against the seams,
   all §6 scenarios 1-11 green with fakes. Gate: tests green.
4. Real adapters. AudioCapture, TranscriptionEngine with model download
   manager, KeyMonitor, TextInserter. Gate: end-to-end dictation into
   TextEdit works: hold key, speak, release, text appears; tests still
   green.
5. Product UI. Menu tree with all items live, pill ported and wired,
   onboarding window, log window, editors, login item. Gate: manual
   checklist in §11 passes except the side-by-side items.
6. Polish and handover. Settings/stats import from the Python app via an
   explicit "Import from Open Whisper (Python)…" menu action using
   `NSOpenPanel` pointed at `~/Library/Application Support/Open Whisper/`
   (sandbox-legal because user-selected), `swift/README.md` with build,
   signing, and App Store archive notes, Makefile target, this plan's
   checklist updated with results.

## 10. Accepted divergences from the Python app

Everything not on this list must match.

- Engine is WhisperKit/CoreML, not MLX: transcripts will differ slightly;
  first use of a model has a one-off CoreML compile delay (show it in the
  UI); GPU-memory logging is replaced.
- Single process: no supervisor auto-restart; watchdogs plus the Restart
  menu item carry that load.
- Minimum macOS 14 (Python app: 13).
- Config file format may change from YAML if JSON is chosen; keys and
  defaults do not change.
- `distil-medium` may be unavailable (greyed out) pending §7.
- State lives in the app container, not directly in
  `~/Library/Application Support/Open Whisper/`; the import action bridges
  it once.

## 11. Definition of done: manual checklist for Sam

After the agent finishes, verify on this Mac:

- [ ] Onboarding appears on first run; granting the two permissions
      advances it without a restart.
- [ ] Hold Right Shift in TextEdit, speak, release: text appears in 1-2 s;
      pill shows and hides correctly in both translucent and solid styles.
- [ ] A long dictation (>30 s) streams: release-to-text wait stays short.
- [ ] Short dictation leaves the clipboard untouched; long dictation
      restores the previous clipboard after ~1.5 s.
- [ ] Escape cancels a live recording; nothing is typed.
- [ ] Switch models from the menu; download shows progress; dictation
      works on the new model.
- [ ] Yank a Bluetooth mic mid-recording: app recovers, next dictation
      works, no stuck pill, no dead trigger key.
- [ ] Stats and time-saved lines update after dictations; import brings
      across the Python app's lifetime numbers.
- [ ] Launch at Login toggle works; app survives logout/login.
- [ ] `xcodebuild test` green; `codesign -dv` shows sandbox on and the
      `Open Whisper Dev` authority.

Side-by-side note: both apps default to Right Shift. When testing them
together, change one app's trigger (e.g. `alt_r+shift_r`) or quit the
Python app; two listen-only taps do not conflict technically, but both
apps will react to the same key.
