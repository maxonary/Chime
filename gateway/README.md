# Chime gateway

## GPT-Live voice

The Watch connects to `WS /v1/live` using `Authorization: Bearer <gateway-token>`.
The gateway authenticates before opening an upstream connection and keeps the
OpenAI project key on the server. Live voice does not require Anthropic, Perplexity,
or a LiveKit worker.

```bash
cd gateway
npm ci
cp .env.example .env
# Set OPENAI_API_KEY and a unique GATEWAY_TOKENS=token:user pair.
npm start
```

Use an OpenAI project with access to `gpt-live-1` and the configured
`LIVE_BACKEND_MODEL` (default `gpt-5.6-luna`). Web search runs through Responses
delegation when enabled in Watch settings. Claude memory and connected-app tools
are separate legacy routes; they are not exposed in this voice session.

The Watch sends `chime.session.start` with `voice`, `research`, and optional
`history` entries (`role`: user/assistant, `content`: text). The gateway starts
GPT-Live with a server-owned prompt, model, audio format, and tool configuration.
After `session.started`, clients may send `session.input_audio.append` (base64,
mono PCM16 little endian, 24 kHz), `session.input_audio.mute`,
`session.input_audio.unmute`, or `session.close`. Other commands are rejected.

The relay forwards audio deltas, both speakers’ transcript deltas and timestamps,
input-state acknowledgments, voice usage snapshots, and final session usage.
Backend events and resolved session configuration stay on the server. Audio queues
are bounded; clients that fall behind must reconnect rather than accumulating
stale audio. Connections have a startup deadline and a ping heartbeat. A disconnected
Watch triggers `session.close`; the gateway waits up to 15 seconds for finalization.
Usage snapshots are cumulative and must not be summed.

For remote use, deploy behind HTTPS/WSS with WebSocket upgrade support. A gateway
path prefix must be stripped by the reverse proxy. Keep the connection open until
`session.closed`; muting alone does not end a billed session.

Validation: `npm run typecheck` and `npm test`. Tests use a local mock upstream and
never call a paid API. Protocol reference: [GPT-Live WebSockets](https://developers.openai.com/api/docs/guides/voice-websockets?api=live).

## Compiled conversation memory

Authenticated `POST /v1/memory` accepts `{memory: {facts: [], context: ""}, turns: [{role, content, timestamp}]}`.
It uses the server-configured Responses model with strict structured output and `store: false`.
The summary holds at most 12 facts (180 UTF-16 units each) and 1,200 units of ongoing context.
Only user-confirmed details should be retained; corrections and requests to forget override old facts.
Conversation content is untrusted data, not system instructions. Model summaries remain lossy and fallible.

The Watch owns the durable summary and per-turn checkpoints. It processes bounded batches, retries
failed updates on the next foreground/call end, and prunes covered source text only after saving memory.
The gateway stores no memory on Render disk, so service restarts do not erase it. It accepts at most
32 turns / 48 KB per request and one in-flight compilation per authenticated user; provider failures
leave the Watch's previous summary intact. The memory request timeout is 30 seconds.

`chime.session.start` also accepts this `memory` object. It enters the voice session as historical
user context with a 3,500-byte cap; combined memory and recent history are capped at 8,000 bytes.
This app-managed summary is separate from Responses conversation IDs and encrypted compaction items.
See OpenAI's [conversation state](https://developers.openai.com/api/docs/guides/conversation-state)
and [structured outputs](https://developers.openai.com/api/docs/guides/structured-outputs) documentation.

## Connected OpenClaw agent (optional)

Keep GPT-Live as the Watch's voice and delegate agent requests through the gateway:

`Watch → Chime gateway → GPT-Live / Responses → OpenClaw /v1/responses`

Enable the API in AlphaClaw's General page, or enable the Responses HTTP endpoint
in OpenClaw. Configure these **server-side** variables together:

```dotenv
OPENCLAW_BASE_URL=https://your-agent.example.com/v1
OPENCLAW_GATEWAY_TOKEN=<OpenClaw gateway operator token>
OPENCLAW_USER_ID=<user ID from the matching GATEWAY_TOKENS entry>
OPENCLAW_AGENT_ID=main
```

For Cloudflare Access, create a dedicated service token and authorize it with a
Service Auth policy on the Access application protecting the API. Set both
`OPENCLAW_CF_ACCESS_CLIENT_ID` and `OPENCLAW_CF_ACCESS_CLIENT_SECRET` in the hosting
provider's secret environment settings. Browser login cookies do not authorize
server requests. Keep the existing interactive dashboard login policy intact.
The gateway refuses redirects, so an Access login page fails rather than silently
becoming an agent reply.

Only the configured authenticated user receives the OpenClaw tools.
Other users retain ordinary voice service. Model arguments cannot choose a host,
agent, credential, or user identity. The operator token stays off the Watch, and
OpenClaw retains its configured permissions and confirmation requirements. This
credential grants substantial agent access; use a dedicated agent with suitable
tool permissions when sharing a gateway.

The connector sends complete requests, relevant context, and corrections to the
agent. A stable hashed user identifier keeps a separate Chime agent session across
voice calls. OpenClaw owns that session's history and its own workspace memory;
this does not automatically import other chat threads or synchronize the Watch's
compiled summary. **Forget everything on the Watch does not delete OpenClaw's
history or memory.** Manage those through OpenClaw.

Calls wait for the Responses turn to complete before executing; duplicate call IDs
are ignored. `ask_openclaw` keeps ordinary queries and authorized actions serialized
in the stable session. `start_openclaw_research` instead acknowledges a task ID
immediately and uses a separate hashed OpenClaw session per task, so a lookup does
not occupy the normal agent session. Research requests must include their relevant
context because these sessions do not share the stable session's transcript.
OpenClaw's global `agents.defaults.maxConcurrent` still limits actual concurrency.

With `RESEARCH_STORE_PATH` configured, two research requests can run per user, with a
10-minute deadline and at most 100 retained tasks per user for seven days. Jobs belong
to the authenticated user, not the WebSocket: ordinary disconnects detach the voice
listener while research continues. Full saved results are available through
`manage_openclaw_research` (`status` or `cancel`, with a task ID or `all`), the
Memory page, and authenticated `/v1/research` routes. New voice sessions receive
bounded saved-result context; a notification selects the result to discuss.

A deliberate hold-to-stop requests cancellation of pending research. Muting only
changes microphone input. Pending push alerts are suppressed while a voice client
is attached, then sent when detached unless the user has already opened the result.
Push is a delivery hint, not the answer store: denial, network failures, or delivery
limits do not discard the saved result. Only independent OpenClaw research jobs
survive disconnect; ordinary synchronous actions and in-progress Live web searches
are not converted into durable jobs. Use the background research tool for that work.

Research requests instruct OpenClaw to perform lookups only. This is a model
instruction, **not a read-only permission boundary**: configure OpenClaw's own tool
permissions if you need that guarantee. Chime does not auto-approve remote dialogs.
Cancellation and timeout abort the HTTP request and suppress late results, but
cannot guarantee remote work has stopped or undo an action. After a gateway restart,
completed answers remain available; unfinished tasks become `unconfirmed`, with no
automatic remote replay. Request IDs are for tracing, not exactly-once guarantees.

Without `RESEARCH_STORE_PATH`, the gateway retains the earlier session-only behavior
(eight tasks, 90-second deadline, cancelled on disconnect). The durable feature must
be configured before distributing a build that promises background completion.

### Durable research and Apple push deployment

1. Keep the existing gateway service on `main` and one instance. Mount a persistent
   disk at `/var/data/chime`; set `RESEARCH_STORE_PATH=/var/data/chime/research.json`.
   This JSON journal uses atomic replacement and private file permissions. It is
   designed for one process; use a transactional database before scaling horizontally.
2. Enable Push Notifications for the iPhone and Watch app identifiers. The app's
   `watch/Chime.entitlements` requests APNs; distribution signing selects production.
3. Configure a server-only APNs signing key using Render secret environment variables:
   `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY` (the `.p8` content),
   `APNS_IOS_TOPIC=maxonary.chime`, and
   `APNS_WATCH_TOPIC=maxonary.chime.watchkitapp`. Never commit the key or bundle it.
4. Grant notification permission when research first starts. Both apps register their
   device token at launch; Debug uses sandbox and TestFlight uses production. The
   server restricts topics and device platform/environment values. Tokens are bounded
   to eight per authenticated user. Identical payloads are sent to the paired devices
   so Apple's notification forwarding can deduplicate them.
5. Verify on hardware: start research, leave the app, wait for its alert, open the
   notification, and ask a follow-up about the saved result. Repeat with notifications
   denied (the answer must still be in Memory), and with a hold-to-stop (no late answer).

The server retries pending delivery every 15 seconds, removes APNs-invalidated tokens,
and expires undelivered alerts after one day. Saved jobs expire after seven days.
**Forget everything** cancels and deletes saved gateway research too; if offline, the
app records a pending deletion and performs it before loading old research into voice.
This still does not erase OpenClaw's own memory or history.

Deployment check: first verify authenticated `GET /v1/models` from outside the
browser, then ask the Watch a harmless agent question and confirm the resulting
Chime session in OpenClaw. Do not report the connection as active based only on a
successful build or dashboard login.

References: [OpenClaw concurrency](https://docs.openclaw.ai/concepts/queue),
[AlphaClaw API proxy](https://github.com/chrysb/alphaclaw#openai-compatible-v1-proxy),
[OpenClaw Responses API](https://docs.openclaw.ai/gateway/openresponses-http-api),
[GPT-Live delegation](https://developers.openai.com/api/docs/guides/live-delegation),
and [Cloudflare service tokens](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/).

## Legacy action agent (optional)


Run VisionClaw's action agent in the cloud so users don't have to install and
host a local agent on their own machine. The gateway speaks the exact protocol
the iOS/Android apps already use (OpenAI-compatible `/v1/chat/completions` +
the WebSocket event channel), and drives
[Anthropic Managed Agents](https://platform.claude.com/docs/en/managed-agents/overview)
behind it: one durable session per user, a mounted long-term memory store, a
per-user credential vault, and a hosted sandbox for tool execution (web search,
files, bash) — no sandbox infrastructure to operate.

```
iOS / Android app  (unchanged)
  ├── POST /v1/chat/completions ─┐
  └── ws:// events ◄─────────┐   │
                             │   ▼
                        this gateway
                             │
                             ▼
              Anthropic Managed Agents (beta)
                1 shared agent config + environment
                1 session + memory store + vault per user
```

## Quick start

```bash
cd gateway
npm install
cp .env.example .env        # set ANTHROPIC_API_KEY and GATEWAY_TOKENS
npm run provision           # creates the shared environment + agent (once)
npm run dev                 # gateway on :8788
```

`GATEWAY_TOKENS` maps client tokens to user ids, e.g.
`GATEWAY_TOKENS="s3cret-a:alice,s3cret-b:bob"`. Each user's session, memory
store, and vault are provisioned lazily on first request (or eagerly via
`npm run provision -- alice bob`).

**App setup** (Settings → Agent): host = `http://<gateway-host>`, port = `8788`,
gateway token = the user's token. Local self-hosted mode keeps working — this
is an alternative backend, not a replacement.

## Endpoints

| Route | Purpose |
|---|---|
| `GET /v1/chat/completions` | reachability probe (the app's connection check) |
| `POST /v1/chat/completions` | one agent turn. Sends only the newest user message — the managed session owns durable history (server-side compaction included). With `"stream": true`, responds with OpenAI-style SSE chunks generated live from the agent's output |
| `POST /context` | queue voice-session context (`{"context": "..."}`); it attaches to the user's next turn as a system-level event (the API rejects standalone system messages) |
| `GET /tasks?limit=N` | recent delegated tasks + results, for the app's Recent Tasks view |
| `GET /apps` | connectable apps and whether this user has linked each one |
| `GET /connect/:app?token=…` | starts the OAuth flow (open in an in-app auth sheet); the callback stores an `mcp_oauth` credential in the user's vault |
| `ws://host:port` | event channel; same protocol-v3 handshake as the local gateway. Late task results arrive as `heartbeat` events, scheduled-task summaries as `cron` events |

## Two-speed turns

`POST /v1/chat/completions` waits up to `QUICK_ANSWER_TIMEOUT_MS` (default 30s).
If the agent is still working, the call returns an acknowledgement immediately
and the final result is pushed over the WebSocket when it lands — the voice
layer never blocks on a long task. The same budget applies to streaming
requests: past it, the stream closes with an acknowledgement chunk and the
final text arrives as a proactive event.

## Connecting apps

Extensions are MCP servers declared once on the shared agent config, with
per-user OAuth credentials in that user's vault (Anthropic refreshes the
tokens). Adding one means a new entry in `src/apps.ts` — the connect routes,
the vault write, and the `/apps` listing are generic. Entries are offered only
when enabled and their MCP URL resolves, so a self-hosted app stays hidden
until it is deployed.

After the OAuth callback the gateway makes one real `tools/call` against the
server before reporting success: a valid grant does not guarantee the server
will serve that account, and "connected" should not claim otherwise.

### Google Calendar

Google's own Calendar MCP server (`calendarmcp.googleapis.com`) is **disabled in
the registry**. It ships under the Google Workspace Developer Preview Program:
with a personal Gmail account `initialize` and `tools/list` succeed but every
`tools/call` returns "The caller does not have permission" — verified with a
direct token call, while the same token works fine against the Calendar REST
API. It needs a Workspace account plus preview enrollment, so it cannot serve
consumer users.

Instead, run [`taylorwilsdon/google_workspace_mcp`](https://github.com/taylorwilsdon/google_workspace_mcp)
(MIT) in external-OAuth mode, where it accepts the bearer token the vault
injects rather than running its own OAuth flow, and calls the Google REST APIs
underneath — which works with consumer accounts:

```bash
docker run -p 8000:8000 \
  -e MCP_ENABLE_OAUTH21=true \
  -e EXTERNAL_OAUTH21_PROVIDER=true \
  -e GOOGLE_OAUTH_CLIENT_ID="<same client id the gateway uses>" \
  -e WORKSPACE_MCP_TOOLS="calendar" \
  workspace-mcp --transport streamable-http --read-only
```

Then point the gateway at it — the app stays hidden until this is set:

```
WORKSPACE_MCP_URL=https://your-workspace-mcp.example.com/mcp/
```

The same deployment also serves Gmail, Tasks, Drive and more: widen
`WORKSPACE_MCP_TOOLS` and add a registry entry with the matching scopes.

To set up the Google side:

1. Create a Google Cloud project; enable **Google Calendar API** and
   **Google Calendar MCP API**.
2. Configure the OAuth consent screen and set publishing status to **In
   production** — in *Testing* status Google expires refresh tokens after 7
   days, which silently breaks stored credentials.
3. Create a Web application OAuth client with redirect URI
   `<PUBLIC_BASE_URL>/connect/gcal-self/callback`; put the id/secret in `.env`.
4. Unverified apps are capped at 100 users and show a warning screen; submit
   for sensitive-scope verification to lift both.

On-device alternative: the iOS app also exposes calendar and reminder tools
backed by EventKit, which need no OAuth at all. Those cover interactive asks;
the connected app is what lets background and scheduled tasks reach the
calendar when the phone is asleep.

## Notes and roadmap

- Managed Agents is an Anthropic **beta**; quotas apply (notably scheduled
  deployments are capped per organization).
- Memory is a per-user mounted store of small text files, versioned and
  redactable server-side.
- Roadmap: more connectable apps (Gmail, Notion, Linear), scheduled reminders
  via deployments, tool-permission prompts surfaced as spoken confirmations,
  Android parity for the backend switcher and local tools.
