# Shipping Open Whisper on the Mac App Store

A concrete plan for getting this app onto the Mac App Store: what has to
change, whether it will still feel the way it does today, and the practical
steps to submit it.

**Verdict up front:** it's viable. The permissions Open Whisper needs are
allowed for sandboxed App Store apps, and other dictation apps ship this way
today. But the current Python/py2app architecture cannot be submitted — not
because it's badly built, but because App Store rules explicitly require an
Xcode-built, sandboxed, self-contained bundle. The route to the store is a
port to a native Swift app. The good news is that the hard-won logic in
`daemon.py` is portable, and the speech engine you'd move to is arguably
better than what you have.

---

## 1. The permission question, settled

This is the thing that determines whether the whole idea is possible, so it's
worth being precise.

**In plain English:** macOS has a System Settings panel called
"Accessibility" that apps ask permission to use. Everyone — including me,
earlier in this project — assumes that's one permission. It isn't. It's
actually *three* separate permissions under the hood, and only one of them is
banned for App Store apps. Open Whisper happens to use the two that are
allowed.

The three, by their internal names:

| Permission | What it does | Open Whisper uses it? | Allowed in a sandboxed App Store app? |
|---|---|---|---|
| `ListenEvent` | Watch keystrokes system-wide (`CGEventTap`) | Yes — detecting your trigger key | **Yes** |
| `PostEvent` | Inject keystrokes into other apps (`CGEvent.post`) | Yes — typing your transcript | **Yes** |
| `Accessibility` | Inspect and drive other apps' UI (`AXUIElement`) | **No** | No |

Apple's own DTS engineer, in
[developer forum thread 820594](https://developer.apple.com/forums/thread/820594):

> "The APIs gated by the `Accessibility` privilege are not compatible with
> the App Sandbox... The APIs gated by the other two privileges *are*
> compatible with the App Sandbox."
>
> "The Mac App Store requires that all code be sandboxed. In my experience
> this isn't an impediment to apps that rely on the `PostEvent` and
> `ListenEvent` privileges, because those are compatible with the App
> Sandbox."

The confusion is Apple's fault, and they acknowledge it: **both `PostEvent`
and `Accessibility` show up as "Accessibility" in System Settings.** Quinn
(the DTS engineer) calls that mapping "a clear source of confusion."

**Precedents:**

- In [thread 756130](https://developer.apple.com/forums/thread/756130), a
  developer states plainly: *"I have two apps in the Mac App Store that can
  request and use Accessibility permission."* In the same thread Apple
  confirms `CGEventTap` works sandboxed, and that
  `AXUIElementCreateApplication()` does not.
- **Voice Type** ([App Store listing](https://apps.apple.com/us/app/voice-type-local-dictation/id6736525125?mt=12))
  is a local-Whisper, hold-a-hotkey, insert-at-cursor dictation app shipping
  on the Mac App Store right now. It is the same product shape as Open
  Whisper.

**What this means for our code:** Open Whisper never calls a single
`AXUIElement` API. The only Accessibility touch is `AXIsProcessTrusted()` at
`daemon.py:1731`, used purely as a permission probe — and it's the wrong API
for what we're checking anyway. Replacing it is on the required-changes list
below, and is worth doing regardless of the App Store.

**The risk that remains is policy, not technology.** See §7.

---

## 2. Why the current app can't be submitted

Four clauses of
[App Store Review Guideline 2.4.5](https://developer.apple.com/app-store/review/guidelines/)
apply directly. Quoting Apple:

> **2.4.5(ii)** — "They must be packaged and submitted using technologies
> provided in Xcode; no third-party installers allowed. They must also be
> self-contained, single app installation bundles."

py2app is not an Xcode technology. This alone requires an Xcode project.

> **2.4.5(iii)** — "They may not auto-launch or have other code run
> automatically at startup or login without consent nor spawn processes that
> continue to run without consent after a user has quit the app."

Our architecture is a menu bar app that spawns `daemon.py` as a subprocess
(`menubar.py:1319`), which itself spawns the `overlay` binary
(`daemon.py:731`). We do terminate them on quit, so this is arguably
compliant — but three processes where one would do is a review flag with no
upside once sandboxed.

> **2.4.5(viii)** — "Apps should run on the currently shipping OS and may not
> use deprecated or optionally installed technologies (e.g. Java)"

A bundled Python interpreter sits uncomfortably close to this.

> **2.5.2** — "Apps should be self-contained in their bundles, and may not
> read or write data outside the designated container area."

The Hugging Face model cache lives in `~/.cache/huggingface`, outside any
container. This has to move.

Two more that shape the product rather than block it:

> **2.4.5(vi)** — "They may not present a license screen at launch, require
> license keys, or implement their own copy protection."

So if you ever charge, it must be a StoreKit in-app purchase. No licence
keys.

> **2.4.5(vii)** — "They must use the Mac App Store to distribute updates;
> other update mechanisms are not allowed."

No Sparkle. Apple handles updates, which is one less thing to build.

**On top of the guidelines**, there's a practical problem: App Store binaries
are re-signed by Apple during submission. A py2app bundle containing a Python
framework, hundreds of `.so` files, and MLX's Metal shader binaries is a poor
candidate for that process, and I could find nobody who has done it.

**Conclusion: the port to Swift isn't a preference, it's the entry fee.**

---

## 3. The port, component by component

The plan is a single native Swift app built in Xcode. Everything currently
split across three processes collapses into one.

| Today | Becomes | Notes and trade-offs |
|---|---|---|
| `menubar.py` (rumps) | `NSStatusItem` + SwiftUI | Direct equivalent. `MenuBarExtra` is the modern API |
| `daemon.py` as a subprocess + supervisor | Same process, background actors | **Trade-off:** you lose the supervisor's auto-restart-with-backoff. In one process a crash is a crash. This makes the watchdog logic *more* important to port faithfully, not less |
| `overlay.swift` as a subprocess | A window in the same process | You already wrote this in SwiftUI — it's the easiest piece. Deletes the stdin-pipe protocol at `daemon.py:748` entirely |
| pynput keyboard listener | `CGEventTap` directly | Removes the LGPLv3 dependency, and gains proper left/right modifier distinction — fixes the flag-mask limitation noted at `daemon.py:196` |
| `_type_unicode` (`daemon.py:969`) | Same `CGEvent` APIs, natively | Near-direct port. Fix the missing pacing between chunks while you're there |
| `pbcopy`/`pbpaste` shelling (`daemon.py:271`) | `NSPasteboard` | **Required** — a sandboxed app shouldn't shell out. Your careful clipboard-verification logic ports as-is; use `changeCount` for ownership |
| `AXIsProcessTrusted()` (`daemon.py:1731`) | `CGPreflightListenEventAccess()` / `CGRequestListenEventAccess()` and the `PostEvent` equivalents | **Required.** These are the correct APIs for what we're actually checking, and they're sandbox-safe |
| `sounddevice` / PortAudio | `AVAudioEngine` | Native, removes a bundled dylib. Your wedged-device recovery logic maps onto engine restart |
| `mlx_whisper` | **WhisperKit** | See §4 |
| `osascript` → Terminal log viewer (`menubar.py:1639`) | In-app log window | **Required** — Apple Events are not available. You already have the `NSScrollView`/`NSTextView` panel from the vocabulary editor |
| `config.yaml` in Application Support | `UserDefaults`, or JSON in the container | Container paths resolve automatically — `paths.py`'s logic mostly survives conceptually |
| `SMAppService` login item | Same API | Works sandboxed. No change needed |
| `py2app` / `build_app.sh` | Xcode project + Archive | **Required** |

### What to port carefully rather than rewrite

The genuinely valuable, hard-to-rediscover parts of this codebase are:

- The recording-lifecycle recovery: wedged stream teardown
  (`daemon.py:1162`), capture health check (`daemon.py:1293`), key watchdog
  (`daemon.py:764`), force reset (`daemon.py:1329`).
- The clipboard safety sequence (`daemon.py:1000`) — verified write, re-check
  before paste, sequence-numbered restore.
- Hallucination filtering (`daemon.py:132`), vocabulary biasing, phonetic
  corrections.

`tests/test_recovery.py` is effectively the written specification for the
first group. **Port it to XCTest first**, then make the Swift implementation
pass it. That way the recovery behaviour is preserved by construction rather
than rediscovered through bugs.

### Trade-offs worth accepting knowingly

- **Minimum macOS goes from 13 to 14** (WhisperKit's floor). Small audience
  cost.
- **Transcripts won't be byte-identical** to today — see §4.
- **The AX text-insertion technique is permanently off the table.** It's the
  cleanest way to insert text (instant, any length, no clipboard) but it's
  the one banned permission. Sandboxing forecloses it.
- **Secure Input** — when a password field is focused, macOS blocks event
  taps entirely. This is already true today; it doesn't get worse.

---

## 4. Will it still perform the way you like it?

The property you find compelling is that **the wait after releasing the key
stays ~1–2 seconds regardless of how long you spoke**, achieved by chunking
at silence gaps and transcribing while you're still talking.

**Short answer: yes, and probably better.**

[WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) (MIT licence, from
Argmax; as of v1.0.0 in May 2026 it ships as part of the Argmax open-source
Swift package) is built for exactly this. From
[their paper](https://arxiv.org/html/2507.10860v1), they modified Whisper's
architecture so the audio encoder *natively supports streaming inference* and
the text decoder produces accurate output from partial audio.

That's a stronger version of what you built by hand. Your approach slices at
silence gaps and transcribes each slice as an independent clip — which is why
you needed `join_streaming_chunks` to clean up the spurious full stops at
boundaries. WhisperKit streams within the model itself, so that class of
problem largely goes away.

Their benchmarks put it at **0.46s latency and 2.2% WER**, compared against
cloud systems including OpenAI's `gpt-4o-transcribe` and Deepgram Nova-3.

It also runs on the Apple Neural Engine as well as GPU and CPU, where MLX is
GPU-only. Practical consequence: **less GPU memory pressure, which makes the
idle-unload feature (`daemon.py:834`) less necessary.** You may be able to
drop that complexity.

### Honest unknowns

1. **Model line-up changes.** WhisperKit uses its own CoreML-converted model
   repository. Your eight-model menu — especially the `distil-*` variants —
   may not map one-to-one. Check availability before committing to the
   settings UI.
2. **Output will differ slightly.** CoreML on the Neural Engine uses
   different numerics from MLX on GPU. Transcripts will be very close but not
   identical. Your hallucination filters and phonetic corrections still apply
   as post-processing, unchanged.
3. **First-load compilation.** CoreML compiles models on first use, adding a
   one-off delay the current app doesn't have. Show it in the UI.
4. **Your streaming logic may become redundant.** That's a win, but budget
   time to work out how much of `StreamingTranscriber` (`daemon.py:437`)
   survives versus gets replaced by WhisperKit's own streaming.

### The alternative, if you want to keep MLX

[MLX Swift](https://mlx-framework.org/) exists, and
[mlx-audio](https://swiftpackageindex.com/Blaizzy/mlx-audio) ships a Swift
package with speech-to-text. This keeps numerics identical to today. It's
less proven for this specific use case than WhisperKit, and you'd be building
the streaming layer yourself again. **Recommendation: WhisperKit.** Fall back
to MLX Swift only if a model you depend on isn't available.

---

## 5. Shipping the models

**The problem in plain English:** Whisper models are big — the turbo model is
around 1.5GB. You either put them inside the app (making the download huge)
or fetch them after install (which App Store rules are twitchy about).

The constraints:

- App Store apps must be **under 4GB uncompressed**
  ([App Store Connect limits](https://developer.apple.com/help/app-store-connect/reference/maximum-build-file-sizes/)).
- **macOS does not support On-Demand Resources**, so Apple's official
  mechanism for large optional assets isn't available to you.
- Guideline **2.4.5(iv)**: apps "may not download or install standalone apps,
  kexts, additional code, or resources to add functionality or significantly
  change the app from what we see during the review process."
- But downloading ML models is normal and Apple documents
  [`MLModel.compileModel(at:)`](https://developer.apple.com/documentation/coreml/reducing-the-size-of-your-core-ml-app)
  for precisely this.

**Recommended approach: bundle one working model, offer the rest as
downloads.**

Ship a small default model (base or small) inside the app so it is fully
functional the moment it launches. Larger models become optional downloads
that improve *quality*, not features.

This threads 2.4.5(iv) cleanly: the reviewer sees a complete, working app,
and nothing downloaded later adds functionality. It also removes the current
first-run failure mode where the menu says "Loading…" for twenty minutes with
no progress indicator.

Store downloaded models **inside the app container**, never in
`~/.cache/huggingface`. Requires the `com.apple.security.network.client`
entitlement.

---

## 6. Getting it live

### Account and costs

| Item | Cost | Notes |
|---|---|---|
| [Apple Developer Program](https://developer.apple.com/programs/whats-included/) | **$99/year** | Enrol as an **individual** — no D-U-N-S number or company needed. Your own name appears as the developer. Approval typically 24–48h |
| App Store commission | **15%** | Via the [Small Business Program](https://developer.apple.com/app-store/small-business-program/), for anyone under $1M/year. You must opt in — it isn't automatic |
| Free app, no IAP | **£0** | No commission at all if you never charge |

Start the enrolment first. It's the only step with a waiting period and zero
effort.

### Entitlements

The complete list for this app:

```xml
<key>com.apple.security.app-sandbox</key>            <true/>
<key>com.apple.security.device.audio-input</key>     <true/>  <!-- microphone -->
<key>com.apple.security.network.client</key>         <true/>  <!-- model downloads -->
```

Plus in `Info.plist`:

```
NSMicrophoneUsageDescription   — why you need the mic, in user-facing language
LSUIElement = true             — menu bar accessory, no Dock icon (already set)
```

**There is no entitlement for `CGEventTap` or `CGEvent.post`.** They're gated
at runtime by TCC, and the user grants them in System Settings. That's why
onboarding matters (below).

Do **not** request hardened-runtime exception entitlements such as
`disable-library-validation`. A pure Swift app needs none of them, and asking
for exceptions invites scrutiny you don't want.

### Build and submit

1. Xcode project, sandbox entitlements as above.
2. Product → Archive.
3. Organizer → Distribute App → App Store Connect.
4. Fill in the App Store Connect record: bundle ID, name, category
   (Productivity), description, keywords, screenshots.
5. **Privacy nutrition label: "Data Not Collected."** This is true for your
   app and it's a genuinely strong listing — say so plainly in the
   description too.
6. Submit for review.

### Onboarding is now a required feature, not a nicety

The app currently has no first-run flow — the README just tells people to
open System Settings themselves. That won't survive review or contact with
users, because two permissions must be granted manually before the app does
anything at all.

Build a first-run window that:

- Explains, in one sentence each, why you need Input Monitoring and
  Accessibility.
- Deep-links straight to the right panes:
  `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`
  and `...?Privacy_ListenEvent`.
- Polls `CGPreflightPostEventAccess()` / `CGPreflightListenEventAccess()` and
  advances automatically once granted.

---

## 7. Framing — how to describe it

You asked whether features need to be framed a certain way. They do, and it
matters more than anything else on this page.

**The one rejection precedent I found** was a clipboard manager, rejected
twice under Guideline 2.4.5 for using `CGEvent.post` to send ⌘V. The reviewer
said *"Accessibility features should not be used for non-accessibility
purposes."* Meanwhile Voice Type ships doing mechanically identical things.

The difference is what the app *is*, and how clearly that's communicated.
Dictation is a recognised, legitimate app category — and genuinely an
accessibility use case. Clipboard automation reads as working around the
system.

So, throughout the listing, the UI, and the review notes:

- **Lead with the user-facing purpose.** It's a dictation app that types what
  you say at your cursor. That's accurate and it's the whole product.
- **Tie each permission to a visible feature.** Input Monitoring → "so it
  knows when you press and hold your dictation key." Accessibility → "so your
  dictated text appears in the app you're typing in."
- **Avoid the vocabulary of automation.** Don't write "simulates keystrokes,"
  "sends ⌘V," "macro," or "keylogger" in anything a reviewer reads.
  Everything you'd say that way has an accurate user-facing equivalent.
- **Keep the clipboard out of the marketing.** It's an internal fallback for
  long text, not a feature.
- **Don't advertise that it works in password fields.** Secure Input blocks
  it anyway, and it sounds alarming.

### Review notes

The notes field is where you pre-empt the rejection. Include:

- What the app does, in one paragraph.
- Exactly which permissions are needed and why, in the user-facing terms
  above.
- Step-by-step instructions to test it: grant the two permissions, open
  TextEdit, hold Right Shift, speak, release.
- **A short screen recording.** This is the single highest-value thing you
  can attach. A reviewer who watches text appear in TextEdit understands the
  app in fifteen seconds.

If rejected, appeal rather than resubmit blindly, and cite the DTS statements
in §1. Apple also runs bi-weekly "Meet with Apple" App Review appointments
where you can ask directly before submitting — worth doing given this app
sits in a grey area.

---

## 8. Risks, honestly

| Risk | Likelihood | Mitigation |
|---|---|---|
| Rejected under 2.4.5 for `CGEvent.post` | Real but not high | Framing (§7), demo video, appeal citing DTS, pre-submission App Review appointment |
| WhisperKit model gaps vs current line-up | Medium | Verify availability before building the settings UI. MLX Swift is the fallback |
| Recovery logic regressions in the port | Medium | Port `test_recovery.py` to XCTest **first** |
| Losing supervisor auto-restart | Certain | Accepted. Single process is what sandboxing wants; watchdogs matter more |
| CoreML first-load delay surprises users | Low | Surface it in the UI |

---

## 9. Suggested sequence

**Phase 0 — de-risk the whole thesis (one evening).**
An Xcode project that does nothing but: sandboxed, `CGEventTap` to detect a
held key, `CGEvent.post` to type a hard-coded string into TextEdit. If that
works sandboxed, every assumption in this document holds. Do not build
anything else until this passes.

**Phase 1 — end to end, ugly.**
WhisperKit with one model, hold-to-talk, text appears at cursor. No settings,
no overlay, no polish.

**Phase 2 — port the valuable logic.**
`test_recovery.py` → XCTest first. Then the recovery paths, clipboard safety,
hallucination filtering, vocabulary, phonetic corrections.

**Phase 3 — the product.**
Menu bar UI, the overlay pill (reuse `overlay.swift` nearly as-is), settings,
recent transcripts, first-run onboarding.

**Phase 4 — submit.**
Screenshots, description, privacy label, review notes, demo video.

---

## Reference links

**Apple — rules**
- [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) — 2.4.5 and 2.5.2 are the relevant clauses
- [Configuring the macOS App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)
- [Entitlements reference](https://developer.apple.com/documentation/bundleresources/entitlements)
- [Maximum build file sizes](https://developer.apple.com/help/app-store-connect/reference/maximum-build-file-sizes/)

**Apple — the permission question**
- [Thread 820594](https://developer.apple.com/forums/thread/820594) — the `PostEvent` / `ListenEvent` / `Accessibility` distinction, and the sandbox compatibility statement
- [Thread 756130](https://developer.apple.com/forums/thread/756130) — a developer with two App Store apps using Accessibility permission; Apple confirms `CGEventTap` works and `AXUIElementCreateApplication` doesn't
- [Thread 780626](https://developer.apple.com/forums/thread/780626) — Input Monitoring vs Accessibility for App Store apps

**Speech engine**
- [WhisperKit / argmax-oss-swift](https://github.com/argmaxinc/argmax-oss-swift) — MIT
- [WhisperKit paper](https://arxiv.org/html/2507.10860v1) — streaming architecture and benchmarks
- [MLX Swift](https://mlx-framework.org/) and [mlx-audio](https://swiftpackageindex.com/Blaizzy/mlx-audio) — the fallback

**Commercial**
- [Apple Developer Program](https://developer.apple.com/programs/whats-included/) — $99/year
- [Small Business Program](https://developer.apple.com/app-store/small-business-program/) — 15% commission

**Precedent**
- [Voice Type on the Mac App Store](https://apps.apple.com/us/app/voice-type-local-dictation/id6736525125?mt=12) — same product shape, shipping today
