import { createHash } from "node:crypto";

export interface AgentBackend {
  userId: string;
  run: (request: string, operationId: string, signal: AbortSignal) => Promise<string>;
}
export interface OpenClawOptions {
  baseURL: string;
  token: string;
  userId: string;
  agentId?: string;
  accessClientId?: string;
  accessClientSecret?: string;
  fetch?: typeof fetch;
  timeoutMs?: number;
}

export const OPENCLAW_TOOL = {
  type: "function", name: "ask_openclaw",
  description: "Ask the user's connected OpenClaw agent about its knowledge, memory, projects, or tools. Send a complete request with relevant context and the user's corrections. Only request actions the user has authorized. Never claim success before the agent confirms it.",
  strict: true,
  parameters: {
    type: "object", additionalProperties: false, required: ["request"],
    properties: { request: { type: "string", description: "The user's request and relevant context, in their language." } },
  },
};

/** One trusted Watch identity per operator credential; never derive routing from model arguments. */
export function createOpenClawBackend(options: OpenClawOptions): AgentBackend {
  const base = new URL(options.baseURL);
  if (base.protocol !== "https:" || base.username || base.password || base.search || base.hash) {
    throw new Error("OPENCLAW_BASE_URL must be HTTPS without credentials, query, or fragment");
  }
  if (!options.token.trim() || !options.userId.trim()) throw new Error("OpenClaw token and authorized user ID are required");
  if (!!options.accessClientId !== !!options.accessClientSecret) throw new Error("Both Cloudflare Access credentials are required");
  const agentId = options.agentId ?? "main";
  if (!/^[a-zA-Z0-9_-]{1,80}$/.test(agentId)) throw new Error("Invalid OpenClaw agent ID");
  const endpoint = new URL(base.href.replace(/\/$/, "") + "/responses");
  const user = "chime-" + createHash("sha256").update(options.userId).digest("hex").slice(0, 32);
  let busy = false;
  return {
    userId: options.userId,
    async run(request, operationId, signal) {
      if (!request.trim() || Buffer.byteLength(request) > 12000) throw new Error("Invalid agent request");
      if (busy) throw new Error("The connected agent is still handling another request");
      signal.throwIfAborted();
      busy = true;
      try {
        const headers: Record<string, string> = {
          Authorization: `Bearer ${options.token}`, "Content-Type": "application/json",
          "x-openclaw-agent-id": agentId,
        };
        if (options.accessClientId && options.accessClientSecret) {
          headers["CF-Access-Client-Id"] = options.accessClientId;
          headers["CF-Access-Client-Secret"] = options.accessClientSecret;
        }
        const response = await (options.fetch ?? fetch)(endpoint, {
          method: "POST", headers, redirect: "error",
          signal: AbortSignal.any([signal, AbortSignal.timeout(options.timeoutMs ?? 90000)]),
          body: JSON.stringify({
            model: `openclaw/${agentId}`, user, stream: false,
            instructions: "You are responding to your owner through Chime on Apple Watch. Voice transcripts can contain errors: ask about ambiguous details before taking action. Keep replies brief and suitable for speech. Follow your existing tool permissions and confirmation requirements. Never auto-approve a pending confirmation. Report an action as completed only after verifying its result. The request ID is for tracing, not a guarantee of exactly-once execution.",
            input: JSON.stringify({ request_id: operationId, request }), max_output_tokens: 1200,
          }),
        });
        if (!response.ok) throw new Error("Connected agent request failed");
        // Bound response allocation even if a proxy or remote agent misbehaves.
        const reader = response.body?.getReader();
        if (!reader) throw new Error("Empty agent response");
        const chunks: Uint8Array[] = [];
        let size = 0;
        try {
          while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            size += value.byteLength;
            if (size > 256000) { await reader.cancel(); throw new Error("Agent response too large"); }
            chunks.push(value);
          }
        } finally { reader.releaseLock(); }
        signal.throwIfAborted();
        const data = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        if (data?.status !== "completed" || !Array.isArray(data.output)) throw new Error("Agent did not complete the request");
        if (data.output.some((item: any) => item?.type === "function_call")) throw new Error("Agent requires an unsupported client tool");
        const text = data.output.filter((item: any) => item?.type === "message")
          .flatMap((item: any) => Array.isArray(item.content) ? item.content : [])
          .filter((part: any) => part?.type === "output_text" && typeof part.text === "string")
          .map((part: any) => part.text).join("\n").trim();
        if (!text || Buffer.byteLength(text) > 16000) throw new Error("Invalid agent response text");
        return text;
      } finally { busy = false; }
    },
  };
}

export function openClawFromEnvironment(env: NodeJS.ProcessEnv = process.env): AgentBackend | undefined {
  if (!env.OPENCLAW_BASE_URL && !env.OPENCLAW_GATEWAY_TOKEN && !env.OPENCLAW_USER_ID) return;
  return createOpenClawBackend({
    baseURL: env.OPENCLAW_BASE_URL ?? "", token: env.OPENCLAW_GATEWAY_TOKEN ?? "",
    userId: env.OPENCLAW_USER_ID ?? "", agentId: env.OPENCLAW_AGENT_ID,
    accessClientId: env.OPENCLAW_CF_ACCESS_CLIENT_ID, accessClientSecret: env.OPENCLAW_CF_ACCESS_CLIENT_SECRET,
  });
}
