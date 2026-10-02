import { createHash, randomUUID, timingSafeEqual } from "node:crypto";
import { setTimeout as delay } from "node:timers/promises";
import type { AgentBackend } from "../openclaw.js";
import { DotStore, type DotMessage, type DotSubscription } from "./store.js";
import { callbackURL, signedHeaders, signingKey, type CallbackPost } from "./webhook.js";

export class DotError extends Error {
  constructor(message: string, public code = -32602, public reason?: string) { super(message); }
}
export function object(value: unknown, keys: string[]): Record<string, any> {
  if (!value || typeof value !== "object" || Array.isArray(value) || Object.keys(value).some(k => !keys.includes(k))) throw new DotError("Invalid arguments");
  return value as Record<string, any>;
}
export function boundedText(value: unknown, max: number): string {
  if (typeof value !== "string" || !value.trim() || Buffer.byteLength(value) > max) throw new DotError("Invalid text or identifier");
  return value;
}
export interface DotOptions {
  owner: string; principal: string; allowedHosts: ReadonlySet<string>; post: CallbackPost;
  /** Recheck BOTH device access and plugin connection before every delivery/tool call. */
  authorized: () => boolean;
  now?: () => number;
}
const EVENT = "message.created";
const TTL = 24 * 60 * 60 * 1000;

export class DotBridge {
  private now: () => number;
  private working = false;
  private closed = false;
  private controllers = new Map<string, AbortController>();
  private verifying = false;
  constructor(private store: DotStore, readonly options: DotOptions) { this.now = options.now ?? Date.now; }
  private access(owner: string) {
    if (this.closed || owner !== this.options.owner || !this.options.authorized()) throw new DotError("Unavailable or unauthorized", -32001);
  }
  private active(sub: DotSubscription) {
    return sub.owner === this.options.owner && sub.principal === this.options.principal && sub.expires > this.now();
  }
  private identity(params: unknown, subscribing: boolean) {
    const p = object(params, subscribing ? ["name", "arguments", "delivery", "cursor", "ttlMs"] : ["name", "arguments", "delivery"]);
    const args = object(p.arguments, ["channel_id"]);
    const delivery = object(p.delivery, subscribing ? ["mode", "url", "secret"] : ["mode", "url"]);
    if (p.name !== EVENT || args.channel_id !== "watch" || delivery.mode !== "webhook" || (p.cursor !== undefined && p.cursor !== null)) throw new DotError("Unsupported event, filter, delivery, or cursor");
    let url: string;
    try { url = callbackURL(delivery.url, this.options.allowedHosts).href; } catch { throw new DotError("Invalid callback destination", -32015, "invalid_url"); }
    const id = "sub_" + createHash("sha256").update(JSON.stringify([this.options.principal, url, EVENT, { channel_id: "watch" }])).digest("hex");
    return { p, delivery, url, id };
  }
  async subscribe(owner: string, params: unknown, grantExpires = Infinity) {
    this.access(owner);
    const { p, delivery, url, id } = this.identity(params, true);
    let secret: string;
    try { secret = signingKey(delivery.secret); } catch { throw new DotError("Invalid signing secret"); }
    if (p.ttlMs !== undefined && p.ttlMs !== null && (!Number.isSafeInteger(p.ttlMs) || p.ttlMs <= 0)) throw new DotError("Invalid ttlMs");
    if (this.verifying) throw new DotError("Subscription verification already in progress", -32000);
    const old = this.store.snapshot().subscriptions.find(s => s.id === id && this.active(s));
    const other = this.store.snapshot().subscriptions.find(s => this.active(s) && s.id !== id);
    if (other) throw new DotError("One dot subscription per owner; unsubscribe before changing destinations", -32000);
    this.verifying = true;
    const abort = new AbortController();
    this.controllers.set(id, abort);
    try {
      let verifiedUntil = old?.verifiedUntil ?? 0;
      // Cache only unchanged secrets; new secrets must prove control again.
      if (!old || old.secret !== secret || old.verifiedUntil <= this.now()) {
        const challenge = randomUUID();
        const body = JSON.stringify({ type: "verification", challenge });
        try {
          const result = await this.options.post(url, body, signedHeaders("verify_" + randomUUID(), id, body, secret), AbortSignal.any([abort.signal, AbortSignal.timeout(10000)]));
          const echoed = Buffer.from(JSON.parse(result.body).challenge ?? "");
          const expected = Buffer.from(challenge);
          if (result.status < 200 || result.status >= 300 || echoed.length !== expected.length || !timingSafeEqual(echoed, expected)) throw new Error();
          verifiedUntil = this.now() + 5 * 60000;
        } catch { throw new DotError("Callback verification failed", -32015, abort.signal.aborted ? "cancelled" : "challenge_failed"); }
      }
      abort.signal.throwIfAborted();
      this.access(owner);
      const expires = Math.min(grantExpires, this.now() + Math.min(p.ttlMs ?? TTL, TTL));
      if (expires <= this.now()) throw new DotError("Access grant expired during verification", -32001);
      this.store.commit(data => {
        data.subscriptions = data.subscriptions.filter(s => s.id !== id && s.expires > this.now());
        data.subscriptions.push({ id, owner, principal: this.options.principal, url, secret, expires,
          verifiedUntil, generation: old?.generation ?? randomUUID(),
          ...(old && old.secret !== secret ? { oldSecret: old.secret, rotateUntil: this.now() + 60000 } :
            old?.rotateUntil && old.rotateUntil > this.now() ? { oldSecret: old.oldSecret, rotateUntil: old.rotateUntil } : {}),
        });
      });
      return { id, refreshBefore: new Date(expires).toISOString(), cursor: null, truncated: false };
    } finally { this.verifying = false; if (this.controllers.get(id) === abort) this.controllers.delete(id); }
  }
  unsubscribe(owner: string, params: unknown) {
    this.access(owner);
    const { id } = this.identity(params, false);
    this.controllers.get(id)?.abort();
    for (const m of this.store.snapshot().messages) if (m.subscriptionId === id) this.controllers.get(m.id)?.abort();
    this.store.commit(data => {
      data.subscriptions = data.subscriptions.filter(s => s.id !== id);
      for (const message of data.messages) if (message.subscriptionId === id && message.state === "pending") message.state = "cancelled";
    });
    return {};
  }
  enqueue(owner: string, operationId: string, text: string): DotMessage {
    this.access(owner);
    boundedText(operationId, 160); boundedText(text, 12000);
    this.expire();
    return this.store.commit(data => {
      const previous = data.messages.find(m => m.owner === owner && m.operationId === operationId);
      if (previous) {
        if (previous.text !== text) throw new DotError("Operation ID already used for different text", -32009);
        return previous;
      }
      if (data.messages.length >= 1000 || data.messages.filter(m => m.state === "pending").length >= 16) throw new DotError("Dot queue capacity reached", -32000);
      const sub = data.subscriptions.find(s => this.active(s));
      if (!sub) throw new DotError("Install, authenticate, and subscribe the dot first", -32000);
      const message: DotMessage = { id: randomUUID(), owner, operationId, text, created: this.now(), deadline: this.now() + 10 * 60000,
        subscriptionId: sub.id, generation: sub.generation, state: "pending", attempts: 0, nextAttempt: this.now(), acknowledged: false };
      data.messages.push(message);
      return message;
    });
  }
  read(owner: string, id: string): DotMessage {
    this.access(owner); boundedText(id, 160); this.expire();
    const message = this.store.snapshot().messages.find(m => m.id === id && m.owner === owner);
    if (!message) throw new DotError("Message not found", -32004);
    return message;
  }
  reply(owner: string, id: string, text: string) {
    this.read(owner, id); boundedText(text, 16000);
    return this.store.commit(data => {
      const m = data.messages.find(m => m.id === id && m.owner === owner)!;
      const sub = data.subscriptions.find(s => s.id === m.subscriptionId && s.generation === m.generation && this.active(s));
      if (!sub) throw new DotError("Message subscription no longer active", -32001);
      if (m.state === "replied" && m.reply === text) return { message_id: id, status: "replied" };
      if (m.state !== "pending") throw new DotError("Message already finalized", -32009);
      m.reply = text; m.state = "replied";
      return { message_id: id, status: "replied" };
    });
  }
  cancel(owner: string, id: string) {
    this.read(owner, id);
    this.controllers.get(id)?.abort();
    return this.store.commit(data => {
      const m = data.messages.find(m => m.id === id && m.owner === owner)!;
      if (m.state === "pending") m.state = "cancelled";
      return m;
    });
  }
  private expire() {
    const expired = this.store.snapshot().messages.some(m => m.state === "pending" && m.deadline <= this.now());
    if (expired) this.store.commit(data => { for (const m of data.messages) if (m.state === "pending" && m.deadline <= this.now()) m.state = "expired"; });
  }
  /** One bounded pass. Attempt is durable BEFORE network I/O; a crash may consume
   * an attempt, but cannot create a new event ID or an unbounded retry loop. */
  async deliver() {
    if (this.working || this.closed) return;
    this.working = true;
    try {
      this.access(this.options.owner); this.expire();
      for (const candidate of this.store.snapshot().messages) {
        this.access(this.options.owner);
        const m = this.read(this.options.owner, candidate.id);
        if (m.state !== "pending" || m.acknowledged || m.nextAttempt > this.now()) continue;
        const sub = this.store.snapshot().subscriptions.find(s => s.id === m.subscriptionId && s.generation === m.generation && this.active(s));
        if (!sub || m.attempts >= 5) { this.failDelivery(m.id); continue; }
        this.store.commit(data => {
          const current = data.messages.find(item => item.id === m.id)!;
          current.attempts++;
          current.nextAttempt = this.now() + Math.min(60000, 1000 * 2 ** current.attempts);
        });
        const eventId = "evt_" + m.id;
        const body = JSON.stringify({ eventId, name: EVENT, timestamp: new Date(m.created).toISOString(),
          data: { channel_id: "watch", message_id: m.id }, cursor: null });
        const abort = new AbortController();
        // Key by message, so unsubscribe also explicitly aborts matching deliveries.
        this.controllers.set(m.id, abort);
        let status = 0;
        try {
          status = (await this.options.post(sub.url, body,
            signedHeaders(eventId, sub.id, body, sub.secret, (sub.rotateUntil ?? 0) > this.now() ? sub.oldSecret : undefined),
            AbortSignal.any([abort.signal, AbortSignal.timeout(10000)]))).status;
        } catch { /* network failure: persisted backoff governs next pass */ }
        finally { this.controllers.delete(m.id); }
        this.store.commit(data => {
          const current = data.messages.find(item => item.id === m.id)!;
          if (status >= 200 && status < 300) current.acknowledged = true;
          else if (current.state === "pending" && ([410, 413].includes(status) || (status >= 400 && status < 500 && status !== 429) || current.attempts >= 5)) current.state = "delivery_failed";
        });
      }
    } finally { this.working = false; }
  }
  private failDelivery(id: string) { this.store.commit(data => { const m = data.messages.find(m => m.id === id)!; if (m.state === "pending") m.state = "delivery_failed"; }); }
  /** Future transcript adapters must call this directly per finalized user turn;
   * do not inject into GPT-Live's optional ask_openclaw delegation. */
  backend(): AgentBackend {
    return { userId: this.options.owner, kind: "dot", run: async (request, operationId, signal, mode) => {
      signal.throwIfAborted();
      if (mode) throw new DotError("Dot research delegation is unsupported");
      const message = this.enqueue(this.options.owner, operationId, request);
      try {
        while (true) {
          signal.throwIfAborted();
          const latest = this.read(this.options.owner, message.id);
          if (latest.state === "replied") return latest.reply!;
          if (latest.state !== "pending") throw new DotError("Dot result unconfirmed: " + latest.state);
          await delay(100, undefined, { signal });
        }
      } catch (error) {
        if (signal.aborted) this.cancel(this.options.owner, message.id);
        throw error;
      }
    } };
  }
  close() { this.closed = true; for (const abort of this.controllers.values()) abort.abort(); }
}
