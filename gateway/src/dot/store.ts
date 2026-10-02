import { randomUUID } from "node:crypto";
import { closeSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

export type DotMessage = {
  id: string; owner: string; operationId: string; text: string; created: number; deadline: number;
  subscriptionId: string; generation: string;
  state: "pending" | "replied" | "cancelled" | "expired" | "delivery_failed";
  reply?: string; attempts: number; nextAttempt: number; acknowledged: boolean;
};
export type DotSubscription = {
  id: string; owner: string; principal: string; url: string; secret: string;
  oldSecret?: string; rotateUntil?: number; expires: number; verifiedUntil: number; generation: string;
};
export type DotSnapshot = { version: 1; messages: DotMessage[]; subscriptions: DotSubscription[] };
const openPaths = new Set<string>();

/** Bounded single-process prototype journal, fsynced before publishing mutations.
 * Keep idempotency tombstones: capacity exhaustion fails closed instead of replaying
 * an old action after a hidden retention window. A lock prevents two writers. */
export class DotStore {
  private data: DotSnapshot;
  private available = true;
  private lock: string;
  private path: string;
  constructor(path: string) {
    this.path = resolve(path);
    this.lock = this.path + ".lock";
    mkdirSync(dirname(this.path), { recursive: true, mode: 0o700 });
    if (openPaths.has(this.path)) throw new Error("Dot store already open");
    try {
      const fd = openSync(this.lock, "wx", 0o600);
      try { writeFileSync(fd, String(process.pid)); fsyncSync(fd); } finally { closeSync(fd); }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
      // Never guess whether an existing PID belongs to us. After an unclean
      // shutdown the operator must confirm no writer is alive and remove lock.
      throw new Error("Dot store locked; see docs/chatgpt-dot-bridge.md recovery steps");
    }
    openPaths.add(this.path);
    try {
      try { this.data = JSON.parse(readFileSync(this.path, "utf8")); }
      catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
        this.data = { version: 1, messages: [], subscriptions: [] };
      }
      this.validate(this.data);
      this.commit(d => d);
    } catch (error) { this.close(); throw error; }
  }
  private validate(data: DotSnapshot) {
    if (data.version !== 1 || !Array.isArray(data.messages) || !Array.isArray(data.subscriptions) || data.messages.length > 1000 || data.subscriptions.length > 16) throw new Error("Invalid dot journal");
    if (new Set(data.messages.map(m => m.id)).size !== data.messages.length ||
        new Set(data.messages.map(m => JSON.stringify([m.owner, m.operationId]))).size !== data.messages.length ||
        new Set(data.subscriptions.map(s => s.id)).size !== data.subscriptions.length) throw new Error("Duplicate dot journal identity");
    for (const m of data.messages) {
      if (![m.id, m.owner, m.operationId, m.text, m.subscriptionId, m.generation].every(v => typeof v === "string" && v.length > 0) ||
          ![m.created, m.deadline, m.attempts, m.nextAttempt].every(Number.isFinite) ||
          !["pending", "replied", "cancelled", "expired", "delivery_failed"].includes(m.state) ||
          typeof m.acknowledged !== "boolean" || (m.state === "replied" && typeof m.reply !== "string")) throw new Error("Invalid dot message");
    }
    for (const s of data.subscriptions) {
      if (![s.id, s.owner, s.principal, s.url, s.secret, s.generation].every(v => typeof v === "string" && v.length > 0) ||
          ![s.expires, s.verifiedUntil].every(Number.isFinite)) throw new Error("Invalid dot subscription");
    }
  }
  snapshot(): DotSnapshot {
    if (!this.available) throw new Error("Dot journal unavailable");
    return structuredClone(this.data);
  }
  commit<T>(change: (draft: DotSnapshot) => T): T {
    if (!this.available) throw new Error("Dot journal unavailable");
    const draft = structuredClone(this.data);
    const result = change(draft);
    this.validate(draft);
    const temp = this.path + "." + randomUUID() + ".tmp";
    try {
      const fd = openSync(temp, "wx", 0o600);
      try { writeFileSync(fd, JSON.stringify(draft)); fsyncSync(fd); } finally { closeSync(fd); }
      renameSync(temp, this.path);
      const directory = openSync(dirname(this.path), "r");
      try { fsyncSync(directory); } finally { closeSync(directory); }
      this.data = draft;
    } catch (error) {
      this.available = false; // An ambiguous disk outcome must never acknowledge success.
      try { unlinkSync(temp); } catch { /* already renamed */ }
      throw error;
    }
    return structuredClone(result);
  }
  close() {
    if (!openPaths.delete(this.path)) return;
    this.available = false;
    unlinkSync(this.lock);
  }
}
