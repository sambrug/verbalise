# macOS permission behaviour

Open Whisper needs three macOS privacy grants:

- **Microphone** — records dictation audio.
- **Input Monitoring** — observes the trigger key globally.
- **Accessibility** — posts the keystrokes used to insert the transcript.

These are separate macOS privacy records and do not all behave like the
Microphone permission.

## Observed first-run behaviour

The Microphone permission normally presents Apple's standard permission dialog
and the app can immediately reflect the result.

Input Monitoring and Accessibility can behave differently. On some macOS
versions/build identities, the app may not appear in the relevant System
Settings list immediately after the request. The user may need to open the
privacy pane, click **+**, select the installed Open Whisper app, and enable
it. The app may not observe the new grant until macOS refreshes its TCC state
(or the app is relaunched).

This is macOS behaviour rather than something the app can safely simulate by
changing the toggle itself. Open Whisper therefore treats System Settings as
the authority and re-checks the grants while the Permissions pane is open.

## Implementation notes

Input Monitoring and PostEvent requests use `IOHIDRequestAccess` and status
checks use `IOHIDCheckAccess`. Apple documents these APIs for requesting and
checking keyboard listen/post access; they are preferable here to relying only
on event-tap creation as a permission request.

The key tap is rebuilt when Input Monitoring becomes available. A full app
restart is not part of the intended permission flow; Restart remains an
advanced troubleshooting action rather than a required onboarding step.

## Testing

For a clean local permission test, quit Open Whisper and reset its TCC records:

```sh
tccutil reset Microphone com.sambruggen.openwhisper
tccutil reset ListenEvent com.sambruggen.openwhisper
tccutil reset PostEvent com.sambruggen.openwhisper
```

Then launch the installed app and test each row from Settings → Permissions.
