# Chime — live conversation on Apple Watch

Chime is a native SwiftUI Watch app for talking with **GPT-Live**. Tap once to
start a conversation, talk naturally, and tap again to end it. The gateway relays
streaming audio to OpenAI while keeping the API key off the Watch.

## What’s included

- A full-screen photographic soap bubble with moving reflections and distinct listening/speaking motion.
- A reminder that appears after 10 idle seconds; swipe horizontally to reach memory (left page) and preferences (right page), with no vertical scrolling on the bubble.
- Streaming audio using `gpt-live-1`, with tap-to-start/end controls and independent user/assistant captions.
- Automatic compact memory of useful facts and ongoing context, saved on the Watch.
- Voice selection and optional web search through OpenAI Responses delegation.
- Automatic connection provisioning during personal-device installation, microphone permission handling, and connection errors.

The app ends its session when it enters the background. Mute leaves the session
active; use End to disconnect. Audio is not saved to files by Chime. Memory is compiled after calls through OpenAI Responses and saved locally before older
transcripts are pruned. The latest 12 turns remain for continuity; failed updates retain
their source turns for retry. Memory and bounded recent text accompany the next session.
This is app-managed memory, not ChatGPT account memory or cross-device cloud sync.
The left page shows remembered facts and offers a confirmed “Forget everything” action.

The Watch currently takes turns: microphone input is silenced during the agent’s
reply and its short acoustic tail, so speaking over the reply does not interrupt it.
This prevents speaker echo without the voice-processing audio unit, which failed
at startup on the tested Series 8. The audio session activates asynchronously
before opening the WebSocket, as required for networking on that Watch.
The bubble respects Reduce Motion and pauses animation on a dimmed or inactive display, or while another page is visible.
See [artwork provenance and prompt](watch/ARTWORK.md).

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

1. Open `chime.xcodeproj` in Xcode. The project targets **watchOS 26.5+**; configure your signing team.
2. Connect your Watch through its paired iPhone and obtain its ID with `xcrun devicectl list devices`.
3. Configure the private Watch token in the ignored `gateway/.env` (or set `WATCH_TOKEN`). Then install:

   ```bash
   GATEWAY_URL=https://your-gateway.example.com ./scripts/install-watch.sh YOUR_WATCH_ID
   ```

   Use `--fresh` on the first installation if no preferences file exists. The installer merges
   credentials into device preferences without embedding them in the bundle, preserving voice
   preferences and memory. This personal development workflow is not public account enrollment.
4. Tap the bubble and allow microphone access. Swipe left for preferences or right for memory;
   no connection fields need to be entered on the Watch.

Use HTTPS/WSS for a remote gateway, with WebSocket upgrades enabled. `localhost`
on a physical Watch refers to the Watch itself, so use a reachable gateway hostname.
The OpenAI API key goes only in the gateway environment, never in Watch settings.
Verify audio, echo behavior, interruptions, and Bluetooth routing on real
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

This runs audio conversion, transcript persistence, and memory lifecycle tests, checks compatibility
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
