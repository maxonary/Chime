# Chime — live conversation on Apple Watch

Chime is a native SwiftUI Watch app for talking with **GPT-Live**. Tap once to
start a conversation, talk naturally, and tap again to end it. The gateway relays
streaming audio to OpenAI while keeping the API key off the Watch.

## What’s included

- A voice-first home screen with connection status, playback status, and elapsed time.
- Continuous two-way audio using `gpt-live-1`, with mute and end controls.
- Independent user and assistant captions, including overlapping speech.
- Locally saved transcripts and recent conversation context on reconnect.
- Voice selection and optional web search through OpenAI Responses delegation.
- Editable gateway settings, microphone permission handling, and connection errors.

The app ends its session when it enters the background. Mute leaves the session
active; use End to disconnect. Audio is not saved to files by Chime. Transcripts
are stored locally on the Watch and recent text is sent as context when reconnecting.

## Run the gateway

Requires Node.js 22+ and an OpenAI project with access to `gpt-live-1` and the
configured Responses backend model.

```bash
cd gateway
npm ci
cp .env.example .env
```

Set these values in `gateway/.env`:

```dotenv
OPENAI_API_KEY=your-openai-project-key
GATEWAY_TOKENS=your-private-watch-token:your-user-id
PORT=8788
LIVE_BACKEND_MODEL=gpt-5.6-luna
```

Then run `npm start`. Check reachability with `curl http://localhost:8788/health`.
The health endpoint checks the gateway process, not OpenAI credentials or model
access. Live voice does not need LiveKit, Anthropic, or Perplexity.

## Run the Watch app

1. Open `chime.xcodeproj` in Xcode. The project currently targets **watchOS 26.5+**.
2. Select the **chime Watch App** scheme and your Watch or Watch simulator.
3. Configure your development signing team for a physical device, then build and run.
4. Open the sliders button in Chime. Set a reachable **Gateway URL** and the private
   Watch token from `GATEWAY_TOKENS`. Choose a voice and whether to enable web search.
5. Tap **Let’s talk** and allow microphone access.

Use HTTPS/WSS for a remote gateway, with WebSocket upgrades enabled. `localhost`
on a physical Watch refers to the Watch itself, so use a reachable gateway hostname.
The OpenAI API key goes only in the gateway environment, never in Watch settings.
Verify duplex audio, echo behavior, interruptions, and Bluetooth routing on real
hardware before distributing a build.

## Architecture

```text
Apple Watch — AVAudioEngine + SwiftUI
    │ authenticated WebSocket /v1/live
    ▼
Chime gateway — Node.js + ws
    │ server-owned session.start, PCM16 mono / 24 kHz
    ▼
OpenAI GPT-Live — gpt-live-1
    └── Responses backend — reasoning and optional web search
```

The gateway waits for `session.started` before accepting audio, allows only audio
and input-control commands, bounds message and output queues, and finalizes the
upstream session when the Watch disconnects. The Watch resamples microphone audio
and plays raw PCM directly without temporary WAV files.

`chime Watch App/` contains the active application. `gateway/src/live.ts` implements
the voice relay. The `agent/` worker and the gateway’s Claude routes remain for
legacy integrations; Claude memory and connected-app tools are not part of the
GPT-Live conversation. See [gateway documentation](gateway/README.md) for details.

## Validation

```bash
cd gateway
npm run typecheck
npm test
```

Run the Watch checks on macOS from the repository root:

```bash
./scripts/check-watch.sh
```

This runs audio conversion and transcript persistence tests, checks compatibility
with existing saved data, and compiles all Watch sources with strict concurrency
checks. It uses the SDK in `/Applications/Xcode.app`; set `DEVELOPER_DIR` if Xcode
is installed elsewhere. These checks do not package, sign, or launch the app.

Gateway tests use a mock GPT-Live upstream and cover authentication, protocol
validation, audio and caption relay, and disconnect cleanup. Build the Watch target
in Xcode and test a live conversation with configured credentials on hardware.

## Troubleshooting

- **Cannot connect:** check gateway reachability, the Watch token, WSS proxy support,
  `OPENAI_API_KEY`, and access to both configured OpenAI models.
- **Microphone unavailable:** allow Chime microphone access in Watch settings.
- **Audio falls behind:** reconnect on a better network. Chime ends sessions with
  excessive buffering rather than playing increasingly delayed speech.
- **Web search unavailable:** enable it in settings before starting a new session.
- **Changes do not apply mid-call:** end the conversation, update settings, then reconnect.

API references: [GPT-Live](https://developers.openai.com/api/docs/guides/live),
[WebSocket audio](https://developers.openai.com/api/docs/guides/voice-websockets?api=live),
[session lifecycle](https://developers.openai.com/api/docs/guides/live-conversations).

## License

See [LICENSE](LICENSE).
