import { randomUUID } from "node:crypto";
import type { AgentBackend } from "./openclaw.js";

type Call = { call_id: string; name: string; arguments: string };
type Group = { responseId: string; calls: Call[]; completed: boolean; running: boolean };

/** Execute only complete server-originated calls, then continue their Responses turn. */
export class AgentTools {
  private groups = new Map<string, Group>();
  private seen = new Set<string>();
  private abort = new AbortController();
  private closed = false;
  private sessionId = randomUUID();
  constructor(private backend: AgentBackend, private send: (event: unknown) => void) {}

  close() {
    this.closed = true;
    this.abort.abort();
    this.groups.clear();
  }

  handle(envelope: Record<string, unknown>) {
    if (this.closed || envelope.type !== "response.event" || typeof envelope.delegation_id !== "string") return;
    const event = envelope.event as any;
    if (!event || typeof event !== "object") return;
    const key = envelope.delegation_id;
    if (event.type === "response.created" && typeof event.response?.id === "string") {
      // Cap per-session bookkeeping and never replace work that is still running.
      if (this.groups.size >= 32 || this.groups.has(key)) return;
      this.groups.set(key, { responseId: event.response.id, calls: [], completed: false, running: false });
    }
    const group = this.groups.get(key);
    if (!group) return;
    if (event.type === "response.output_item.done" && event.item?.type === "function_call" && !group.completed) {
      const call = event.item;
      if (typeof call.call_id !== "string" || typeof call.name !== "string" || typeof call.arguments !== "string") return;
      if (this.seen.has(call.call_id)) return;
      this.seen.add(call.call_id);
      group.calls.push(call);
    }
    if (event.type === "response.completed" && event.response?.id === group.responseId) {
      group.completed = true;
      if (!group.calls.length) { this.groups.delete(key); return; }
      void this.run(key, group);
    }
    if (["response.failed", "response.incomplete"].includes(event.type) && event.response?.id === group.responseId) {
      this.groups.delete(key);
    }
  }

  private async run(key: string, group: Group) {
    if (group.running) return;
    group.running = true;
    for (const call of group.calls) {
      let output: string;
      try {
        if (call.name !== "ask_openclaw" || this.seen.size > 64) throw new Error("Unsupported agent tool");
        const args = JSON.parse(call.arguments);
        if (!args || typeof args.request !== "string" || Object.keys(args).some(key => key !== "request")) throw new Error("Invalid agent arguments");
        const result = await this.backend.run(args.request, `${this.sessionId}:${call.call_id}`, this.abort.signal);
        output = JSON.stringify({ status: "completed", result });
      } catch {
        output = JSON.stringify({ status: "unconfirmed", message: "The connected agent could not confirm a result. An action may already have started; do not retry automatically or claim it succeeded. Ask the user to check the agent before repeating an action." });
      }
      if (this.closed) return;
      this.send({ type: "response.item.create", item: { type: "function_call_output", call_id: call.call_id, output } });
    }
    if (this.closed) return;
    this.groups.delete(key);
    this.send({ type: "response.create" });
  }
}
