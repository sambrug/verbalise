# The App Store record

The operational log for Mac App Store submissions: what was submitted, what
Apple said, what changed in response, and the reply texts. The build itself
is `make mas-archive` (the `VerbaliseMAS` target); `make mas-build` is the
fast compile check.

## Where things stand

**1.0 (build 2), submitted 16 Aug 2026: rejected** on four issues.

| Issue | Resolution |
|---|---|
| 2.4.5(v) — Input Monitoring not allowed on the store | Resolved by removal: the store build's trigger is a registered system hotkey (`HotKey.swift`), so the permission no longer exists in the app. `KeyTap.swift` is excluded from the target entirely. |
| 2.4.5 — "Accessibility for a non-accessibility purpose" | Defended, not removed: automatic insertion keeps the PostEvent grant and the reply below argues it. The prepared fallback is the clipboard insertion mode, already shipped as a setting — see "If the defence fails". |
| 5.1.1(iv) — "Grant" button before the mic prompt | Fixed on main (`fee05ac`): the button says "Continue". |
| 4.3(a) — similarity to other apps | Replied with the originality case below, plus a listing rewrite that stops leading with "Whisper". |

## The submission checklist

1. Bump `CFBundleShortVersionString` / `CFBundleVersion` in
   `Resources/Info-MAS.plist` and the matching `MARKETING_VERSION` /
   `CURRENT_PROJECT_VERSION` in `project.yml`.
2. `make test` and `make mas-build`, then `make mas-archive`; upload via
   Xcode's Organizer with the distribution identity.
3. Tag the exact commit: `git tag appstore-build-<N> && git push --tags`.
4. Paste the review notes below into App Store Connect, attach the demo
   video (screen recording: hold the shortcut in TextEdit, speak, release,
   text appears).
5. Record the outcome in the round log at the bottom of this file.

## Review notes (App Store Connect "Notes" field)

> Verbalise is an offline dictation app. Hold a keyboard shortcut, speak,
> release: your words are transcribed on-device (no audio ever leaves the
> Mac) and appear where your cursor is.
>
> To test: launch the app, press Continue through the microphone prompt,
> open TextEdit, hold Option+D, say a sentence, release. If automatic
> insertion is enabled in Settings > Dictation, grant the Accessibility
> permission when directed and the sentence appears at the cursor; in
> clipboard mode no permission is needed and the app shows "Press Cmd+V to
> paste".
>
> Permissions used: microphone (recording while the shortcut is held), and
> — only when the user selects automatic insertion — the system permission
> macOS lists under Accessibility, used solely to deliver the user's own
> dictated words at their insertion point. The app registers a standard
> system hotkey and does not observe any other keyboard input; it uses no
> AXUIElement APIs and does not read or control other apps' UI.

## Reply: 2.4.5 (the insertion defence)

To send in the resolution thread alongside the resubmission:

> Thank you for the review. We have revised the app substantially:
>
> 1. The app no longer requests Input Monitoring at all. The dictation
>    shortcut is now a registered system hotkey (RegisterEventHotKey), so
>    macOS delivers only that shortcut and the app observes no other
>    keyboard input.
>
> 2. On the Accessibility concern: the app uses no accessibility
>    (AXUIElement) APIs and does not inspect or control other apps. The
>    single remaining use of the permission macOS lists under Accessibility
>    is CGEvent posting to type the user's own dictated words at their
>    insertion point — the product's core function, and one users enable
>    knowingly for that stated purpose. Dictation is assistive input:
>    people who cannot type comfortably (RSI, motor impairment, dyslexia)
>    use Verbalise to write with their voice, and delivering the words at
>    the cursor is what makes that possible.
>
> 3. NSEvent.addLocalMonitor, suggested in the rejection, only observes
>    events in our own app's windows, so it cannot deliver dictation into
>    the app the user is writing in.
>
> 4. The app also ships a clipboard insertion mode that uses no permission
>    at all; the Accessibility-pane grant is requested only for users who
>    choose automatic insertion.
>
> We believe this is an appropriate, disclosed, user-serving use of the
> permission, and we are happy to demonstrate it or answer questions.

## Reply: 4.3(a) (the originality case)

> Verbalise is original work by a sole developer. The codebase was written
> from scratch in Swift as a port of my own earlier open-source Python
> implementation; the full git history is available on request. It uses no
> app template and no purchased code. Its one significant dependency is
> WhisperKit (MIT-licensed, by Argmax), used as a speech-recognition
> framework the same way any app uses a framework — every product feature
> around it is original: streaming transcription with a live waveform pill,
> staged speech-model switching, audio-device recovery, a custom
> vocabulary and phonetic-correction pipeline, and fully offline operation.
> I'd welcome a closer look at the binary or the repository if it helps
> distinguish Verbalise from template resubmissions.

## If the defence fails

The prepared fallback (path B) keeps the release moving:

1. Flip the store build's default insertion mode to clipboard and remove
   the automatic option from that build, so no code path can request the
   contested permission.
2. Bump the build number, re-archive, resubmit with a short note: "the app
   now uses no permission beyond the microphone".
3. The direct build is untouched either way.

Known residue, accepted: `VerbaliseCore` still contains the request
functions in `Permissions.swift` as symbols (the package compiles for both
variants); the store build never calls the Input Monitoring one. If a
future review objects to the symbol itself, split the file out of the
shared package.

One unpulled lever, if a second rejection comes: make the insertion mode an
explicit first-run choice instead of defaulting to automatic. "The user
selected this and then granted the permission for it" is a stronger shape
than "the app asked by default".

## What was tried and abandoned

Dictation as a macOS Service (returned text inserted by the system, zero
permissions) works mechanically everywhere — TextEdit, Safari, Chrome,
VS Code, Slack, even Google Docs — but invocation killed it: services
shortcuts are dispatched by the focused app, so any web or Electron app
that claims the combo silently wins, and the Services menu only refreshes
at login. The spike lives on the unmerged `services-insertion-spike`
branch. Precedents worth remembering: Voice Type ships hold-hotkey
insert-at-cursor dictation on the store today; WhisperPad lost this exact
Accessibility argument twice, including on appeal, and shipped the
clipboard compromise.

## Round log

| Date | Version | Outcome |
|---|---|---|
| 16 Aug 2026 | 1.0 (2) | Rejected: 2.4.5(v), 2.4.5, 5.1.1(iv), 4.3(a) |
| — | 1.0.1 (3) | Prepared; not yet submitted |
