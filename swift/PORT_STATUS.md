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
| 2. Pure logic + fixture tests | In progress | `swift test` green |
| 3. State machine + recovery tests | Not started | `swift test` green |
| 4. Real adapters | Not started | End-to-end dictation into TextEdit |
| 5. Product UI | Not started | Manual checklist, plan §11 |
| 6. Polish + handover | Not started | — |

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
