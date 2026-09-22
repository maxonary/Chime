# Chime on Apple Watch 🫧

Use the existing `chime.xcodeproj`; the active sources are in `chime Watch App/`.
The project targets watchOS 26.5 or later. Live voice has been confirmed on Apple Watch Series 8.

## Install on your Watch

1. Follow the [gateway setup](../README.md#run-the-gateway) and deploy it at an HTTPS URL.
2. Open the project in Xcode, select **chime Watch App**, and configure your signing team.
3. Connect the paired iPhone and make the Watch available to Xcode; obtain its ID with `xcrun devicectl list devices`.
4. Configure the Watch token in the ignored `gateway/.env`, or set `WATCH_TOKEN` locally.
5. From the repository root:

   ```bash
   GATEWAY_URL=https://your-gateway.example.com ./scripts/install-watch.sh YOUR_WATCH_ID
   ```

   Add `--fresh` only for a first installation with no existing preferences file. The script
   builds, installs, merges credentials into device preferences, and launches Chime. Existing
   voice choices and conversation memory are preserved. Credentials are not bundled in the app.
6. Open Chime and allow microphone access. The voice conversation starts automatically and the bubble grows when ready.

This installer is for a personal development device. Public distribution would need account
enrollment. Never put an OpenAI key in the Watch bundle or commit a gateway token.

## Three pages, one conversation

- **Center:** tap the bubble to start/end a call. It is small with the mic off, large with the mic enabled,
  and pulses with audio input/output. Vertical swipes and Crown turns do not move or resize it.
- **Left page:** swipe right from the bubble to see compiled memory. Memory updates automatically.
  Forgetting everything requires confirmation and is disabled during a call.
- **Right page:** swipe left from the bubble for voice, web search, and microphone mute while connected.
  Voice and search changes apply to the next conversation.

An active Watch conversation uses background audio, so lowering your wrist or dimming the display
should not end it. Tap the bubble to end the call when finished; audio interruptions can still end it.
Connection setup must finish while Chime is in the foreground. The iPhone app still ends calls when
it enters the background.

The system time remains at the top. There is no branding, tap hint, or transcript tab on the home page.
Screenshots are in the [main README](../README.md#on-your-wrist).

## Quick access from your wrist

The app includes a WidgetKit extension and an **Open Chime** App Shortcut.

- **Smart Stack:** from the Watch face, turn the Digital Crown upward or swipe up.
  Edit the stack (touch and hold, or use **Edit**), tap **+**, select **Chime**, and
  add its bubble widget. Pin it if you want it to stay near the top.
- **Watch face:** touch and hold the face, choose **Edit**, swipe to **Complications**,
  and assign **Chime** to a supported slot. Circular, rectangular, inline, and corner
  layouts are included; available slots depend on the face.
- **Siri / Shortcuts:** say **“Open Chime”** on the Watch. The app also exposes an
  **Open Chime** action to Shortcuts on the Watch. This Watch-only target does not
  add an iPhone Home Screen widget or an iPhone app action.

Each entry opens the center bubble, even if the app was last showing memory or
preferences. Opening Chime starts the voice conversation once the app is active and configured. These are static launchers:
they do not stream audio, display conversations, or contact the gateway themselves.
A tinted face uses a simple bubble outline; the full-color widget uses the app's
reflective bubble artwork. If Chime is absent from the picker just after installing,
unlock the Watch and open Chime once before returning to the picker.

## Verify a change

Run `./scripts/check-watch.sh` for send cancellation, connection error messages, audio conversion, level metering, transcript persistence,
memory lifecycle, and strict concurrency compilation. Also build the Watch scheme in Xcode; this embeds and compiles **Chime Widgets**.

On a real Watch, check:

1. Opening the configured app starts one voice conversation automatically. End it: the idle bubble stays small and no reminder appears.
2. Vertical swipes and Crown rotation leave the center fixed; horizontal swipes reach both side pages.
3. Open from a widget, complication, app icon, or shortcut: the bubble grows without another tap; speech pulses it, while silence settles it.
4. Agent playback pulses in time with sound. Input is suppressed during playback to prevent echo.
5. Mute shrinks the bubble, unmute grows it, and ending the call returns to the small state.
6. End a conversation, then reconnect and ask about a remembered detail; check memory after a relaunch.
7. Add the Smart Stack widget and a face complication; tap each from a cold launch and
   after leaving the app on a side page. Confirm the bubble opens and starts a single conversation.
8. Run **Open Chime** from Shortcuts or Siri and confirm it returns to the bubble and starts a conversation.
9. Once connected, lower your wrist for at least 30 seconds while speaking and during a reply.
   Raise it and verify that the same call remains active, including on the Series 8 speaker.
10. End a call during an audio send, leave during connection setup, and interrupt audio with another app.
    None should show an operation-cancelled or gateway-token alert. Reconnect afterward.
11. Disable the network during an active call: a real connection failure must still show a reconnect message.
12. Check Reduce Motion, permission denial, and a failed gateway connection. Dismissing an alert or a permission dialog must not trigger repeated start attempts; raising the wrist from the inactive state must not restart a manually ended call.

A simulator can verify layout and navigation; microphone, speaker, and networking behavior still
need hardware checks. The current audio path supports turn-taking rather than spoken interruption.
