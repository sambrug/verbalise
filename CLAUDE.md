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
make test                       # recording-lifecycle and streaming tests
.venv/bin/python3 menubar.py    # run from source
make app && make install        # build dist/Open Whisper.app and copy to /Applications
```

`/Applications` is writable by the `admin` group without `sudo` on a normal
single-admin-user Mac — check with `ls -ld /Applications` before assuming
`make install`'s `sudo` step is actually required.

Run `make test` after any change to `daemon.py` or `menubar.py`; it's fast
and covers real failure modes (wedged audio devices, dead mics, stalled
recordings), not just happy paths.
