# Working in this repo

## Working style

Sam is a Product Manager by career not a developer. He is semi-technical - 
he has a strong interest in coding and AI and picks up concepts fast. Given 
this, lean towards explaining at a more abstract level unless needed or 
specifically asked. At this stage, we are generally 'vibe coding' but he
is comfortable to go in and make manual edits if needed, and navigate GitHub
or other required systems.

## Commit hygiene

This is a personal project so the usual "keep PRs small for
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
