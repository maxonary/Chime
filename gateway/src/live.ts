import type { IncomingMessage, Server } from "node:http";
import { WebSocket, WebSocketServer } from "ws";

const MAX_BUFFER = 512 * 1024;
const VOICES = new Set(["marin", "gleam", "quartz", "willow", "vesper"]);
export interface LiveOptions {
  tokens: Map<string, string>;
  apiKey?: string;
  backendModel: string;
  upstreamURL?: string;
  startupTimeoutMs?: number;
  closeTimeoutMs?: number;
}

/** Own session configuration on the server; clients can send only audio and input controls. */
export function sessionConfiguration(message: Record<string, unknown>, backendModel: string) {
  const history = Array.isArray(message.history) ? message.history.slice(-20) : [];
  // A byte budget is conservative across languages for Live's 8,192-token limit.
  let remaining = 8000;
  const input = history.reverse().flatMap((item) => {
    if (!item || (item.role !== "user" && item.role !== "assistant") || typeof item.content !== "string") return [];
    let text = "";
    for (const character of Array.from(item.content as string).slice(0, 2000)) {
      const bytes = Buffer.byteLength(character);
      if (bytes > remaining) break;
      text += character;
      remaining -= bytes;
    }
    return text ? [{ type: "message", role: item.role, content: [{ type: item.role === "user" ? "input_text" : "output_text", text }] }] : [];
  }).reverse();
  const research = message.research !== false;
  return {
    model: "gpt-live-1",
    instructions: "You are Chime, a warm, concise voice assistant on Apple Watch. Keep answers brief and conversational. " +
      "Listen naturally and let the user interrupt. Delegate complex reasoning to the backend. " +
      (research ? "Delegate questions needing current information to the backend for web search." : "Web search is disabled. Be clear when you cannot verify current information."),
    input,
    store: false,
    audio: { format: { type: "audio/pcm", rate: 24000 }, output: { voice: typeof message.voice === "string" && VOICES.has(message.voice) ? message.voice : "marin" } },
    delegation: { type: "responses", responses: { model: backendModel, tools: research ? [{ type: "web_search" }] : [], tool_choice: "auto" } },
  };
}

export function liveUser(req: IncomingMessage, tokens: Map<string, string>) {
  const header = req.headers.authorization;
  return header?.startsWith("Bearer ") ? tokens.get(header.slice(7).trim()) : undefined;
}

export function attachLiveServer(server: Server, options: LiveOptions) {
  const wss = new WebSocketServer({ noServer: true, maxPayload: 64 * 1024 });
  server.on("upgrade", (req, socket, head) => {
    if ((req.url ?? "/").split("?")[0] !== "/v1/live") return;
    const status = !liveUser(req, options.tokens) ? "401 Unauthorized" : !options.apiKey ? "503 Service Unavailable" : null;
    if (status) {
      socket.end(`HTTP/1.1 ${status}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
      return;
    }
    wss.handleUpgrade(req, socket, head, (client) => bridge(client, options));
  });
  return wss;
}

function bridge(client: WebSocket, options: LiveOptions) {
  let upstream: WebSocket | undefined;
  let started = false;
  let closing = false;
  let finalized = false;
  let closeTimer: ReturnType<typeof setTimeout> | undefined;
  const startupTimer = setTimeout(() => fail("Live connection timed out. Try again."), options.startupTimeoutMs ?? 20000);
  // A half-open Watch connection must not leave a billed session running forever.
  let alive = true;
  const heartbeat = setInterval(() => {
    if (!alive) { client.terminate(); return; }
    alive = false;
    client.ping();
  }, 30000);
  client.on("pong", () => { alive = true; });

  function send(target: WebSocket, event: unknown) {
    if (target.readyState !== WebSocket.OPEN) return;
    if (target.bufferedAmount > MAX_BUFFER) { fail("Connection is too slow for live audio. Reconnect to try again."); return; }
    target.send(JSON.stringify(event));
  }
  function fail(message: string) {
    if (client.readyState === WebSocket.OPEN) {
      client.send(JSON.stringify({ type: "error", error: { message } }));
      client.close(1011, "Live session failed");
    }
    clearTimeout(startupTimer);
    clearInterval(heartbeat);
    closeUpstream();
  }
  function closeUpstream() {
    if (closing) return;
    closing = true;
    clearTimeout(startupTimer);
    if (upstream?.readyState === WebSocket.OPEN && started && !finalized) {
      upstream.send(JSON.stringify({ type: "session.close" }));
      closeTimer = setTimeout(() => {
        upstream?.terminate();
        if (client.readyState === WebSocket.OPEN) {
          client.send(JSON.stringify({ type: "error", error: { message: "Session ended before final usage was confirmed." } }));
          client.close(1011);
        }
      }, options.closeTimeoutMs ?? 15000);
    } else {
      upstream?.terminate();
      client.close(1000);
    }
  }

  client.on("message", (raw, binary) => {
    let message: Record<string, unknown>;
    try {
      message = JSON.parse(raw.toString());
      if (binary || !message || typeof message !== "object" || Array.isArray(message)) throw new Error();
    } catch { fail("Invalid live message."); return; }
    if (message.type === "session.close") { closeUpstream(); return; }
    if (closing) return;
    if (!upstream) {
      if (message.type !== "chime.session.start") { fail("Start a session before sending audio."); return; }
      upstream = new WebSocket(options.upstreamURL ?? "wss://api.openai.com/v1/live/sessions", {
        headers: { Authorization: `Bearer ${options.apiKey}` },
        handshakeTimeout: options.startupTimeoutMs ?? 20000,
        maxPayload: 2 * 1024 * 1024,
      });
      upstream.on("open", () => send(upstream!, { type: "session.start", session: sessionConfiguration(message, options.backendModel) }));
      upstream.on("message", (data) => {
        let event: Record<string, unknown>;
        try {
          event = JSON.parse(data.toString());
          if (!event || typeof event !== "object" || Array.isArray(event)) throw new Error();
        } catch { fail("Invalid response from the voice service."); return; }
        if (event.type === "session.started") { started = true; clearTimeout(startupTimer); }
        if (event.type === "session.closed") { finalized = true; clearTimeout(closeTimer); }
        // Forward voice events, not backend responses or server-owned configuration.
        if (event.type === "session.started") send(client, { type: event.type });
        else if (event.type === "session.closed") send(client, { type: event.type, usage: event.usage, reason: event.reason });
        else if (typeof event.type === "string" && ["session.output_audio.delta", "session.input_transcript.delta", "session.output_transcript.delta", "session.input_audio.muted", "session.input_audio.unmuted", "session.usage.updated"].includes(event.type)) send(client, event);
        else if (event.type === "error") { fail("The voice service could not complete the request. Check gateway configuration and try again."); return; }
        if (finalized) { upstream?.close(); client.close(1000); }
      });
      upstream.on("error", () => fail("Cannot connect to GPT-Live. Check the gateway API key and model access."));
      upstream.on("close", () => {
        clearTimeout(startupTimer);
        clearTimeout(closeTimer);
        if (!finalized && client.readyState === WebSocket.OPEN) fail("Live connection lost. Tap to reconnect.");
      });
      return;
    }
    if (!started) { fail("The voice session is not ready yet."); return; }
    if (message.type === "session.input_audio.append") {
      const audio = message.audio;
      if (typeof audio !== "string" || !audio.length || audio.length > 48000 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(audio) || Buffer.from(audio, "base64").length % 2 !== 0) {
        fail("Audio must be mono PCM16 at 24 kHz."); return;
      }
      send(upstream, { type: message.type, audio });
    } else if (message.type === "session.input_audio.mute" || message.type === "session.input_audio.unmute") {
      send(upstream, { type: message.type });
    } else {
      fail("Unsupported live command.");
    }
  });
  client.on("close", () => { clearInterval(heartbeat); closeUpstream(); });
  client.on("error", () => { clearInterval(heartbeat); closeUpstream(); });
}
