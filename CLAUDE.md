# Working in this repo

## Commit hygiene

This is a personal, unreviewed project, so the usual "keep PRs small for
reviewers" reasoning doesn't really apply here — but atomic *commits* still
do, because `git bisect` and `git revert` care about commit boundaries, not
PR boundaries.

When a change bundles a few genuinely independent concerns (e.g. a UI
tweak + a packaging fix + a behavioral bug fix), split it into one commit
per concern rather than one squashed commit — even within a single PR.
Each commit should be revertable on its own without dragging unrelated
changes with it. A single commit is fine when the change actually is one
thing, even if it touches several files.

Before amending/rewriting pushed history, verify the rewritten diff is
identical to the original (`git diff <old-ref>..<new-ref>` should print
nothing) before force-pushing — a history rewrite should never sneak in
an unintended change.

## Build & test

```bash
make test           # the full test suite, fast, no Xcode needed
make app            # build + sign build/Verbalise.app
make install        # copy it to /Applications/Verbalise.app
```

`/Applications` is writable by the `admin` group without `sudo` on a normal
single-admin-user Mac — check with `ls -ld /Applications` before assuming
`sudo` is required.

Run `make test` after any change to Sources/ — it covers real failure modes
(wedged audio devices, dead mics, stalled recordings), not just happy paths.

Reinstalling to a new path or with a new signing identity voids the TCC
grants (Input Monitoring, Accessibility); the stable "Verbalise Dev"
identity from `make signing-cert` is what lets ordinary rebuilds keep them.

## The legacy Python app

`legacy-python/` is the original implementation, self-contained and
deprecated. Don't reference it from anything outside that directory, and
don't spend effort maintaining it.

## Xcode: Previews and the App Store archive

`swift build`/`make test`/`make app` never need Xcode. `Verbalise.xcodeproj`
(gitignored, `make xcodeproj`) exists only for two things that do: SwiftUI
Previews, and producing an App Store archive.

Previewing a file in the `Verbalise` target (`SettingsPanes.swift`,
`OverlayPill.swift`) needs `ENABLE_DEBUG_DYLIB` on for Debug — already set in
`project.yml`. Even with that, Previews can still be slow or fail with a
misleading "unable to type-check in reasonable time" error, because it
JIT-links this target's *entire* dependency graph on every update, including
WhisperKit/ArgmaxCore, regardless of what the previewed file actually touches.
If that happens, confirm it's not a real code problem first — `swift build
--product Verbalise` compiles in seconds and is the fast way to rule that out
— before assuming the Mac is underpowered or fighting the expression itself.

For the archive: Automatic signing in Xcode's Signing & Capabilities tab is
the path that's actually been used successfully, not hand-editing
`CODE_SIGN_IDENTITY`/`DEVELOPMENT_TEAM` in `project.yml` the way an older
comment there suggests. Xcode switches identities on its own by build action
— Apple Development for Run, Apple Distribution + a Mac App Store profile for
Archive — creating whatever's missing the first time you archive.

`Resources/PrivacyInfo.xcprivacy` must not contain XML comments. It's valid
plist XML either way, but App Store Connect's validator (seen as ITMS-91056,
"Invalid privacy manifest") rejects it anyway if one's present, apparently
using a stricter parser than a generic plist reader. Re-verify
`NSPrivacyAccessedAPITypes` against WhisperKit before each archive regardless
— it's built from source via SwiftPM, so its API use counts as this app's
rather than being covered by a manifest of its own.

Support and the privacy policy page are hosted in a separate public repo,
[`sambrug/verbalise-support`](https://github.com/sambrug/verbalise-support)
— issues for support, `PRIVACY.md` for the policy — kept apart from this
private source repo on purpose.
