import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import type { AgentBackend } from "./openclaw.js";

export type ResearchJob = {
  id: string; userId: string; request: string; started: number; updated: number;
  state: "running" | "completed" | "unconfirmed" | "cancel_requested";
  result?: string; acknowledged?: boolean; notified?: boolean; deliveredTo?: string[];
};
export type PushDevice = { userId: string; token: string; platform: "ios" | "watchos"; environment: "production" | "sandbox"; updated: number };
type Snapshot = { jobs: ResearchJob[]; devices: PushDevice[] };
type Listener = (job?: ResearchJob) => void;
const RETENTION = 7 * 24 * 60 * 60 * 1000;

/** Single-process, bounded persistent job journal. Never replay unconfirmed remote work. */
export class BackgroundResearch {
  private data: Snapshot;
  private storageAvailable = true;
  private running = new Map<string, { abort: AbortController; timer: ReturnType<typeof setTimeout> }>();
  private listeners = new Map<string, Set<Listener>>();
  constructor(private path: string, private deadlineMs = 600000) {
    try { this.data = JSON.parse(readFileSync(path, "utf8")); }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      this.data = { jobs: [], devices: [] };
    }
    if (!Array.isArray(this.data.jobs) || !Array.isArray(this.data.devices)) throw new Error("Invalid research journal");
    // A restart cannot establish whether OpenClaw finished. Preserve that truth,
    // retain completed answers, and never automatically repeat a remote action.
    for (const job of this.data.jobs) if (job.state === "running") { job.state = "unconfirmed"; job.updated = Date.now(); }
    this.persist();
  }
  private persist() {
    this.storageAvailable = false;
    this.data.jobs = this.data.jobs.filter(j => j.updated > Date.now() - RETENTION);
    this.data.devices = this.data.devices.filter(d => d.updated > Date.now() - 30 * RETENTION);
    mkdirSync(dirname(this.path), { recursive: true, mode: 0o700 });
    writeFileSync(this.path + ".tmp", JSON.stringify(this.data), { mode: 0o600 });
    renameSync(this.path + ".tmp", this.path);
    this.storageAvailable = true;
  }
  list(userId: string) { return this.data.jobs.filter(j => j.userId === userId && j.updated > Date.now() - RETENTION).map(j => ({ ...j })); }
  active(userId: string) { return this.list(userId).filter(j => j.state === "running").length; }
  subscribe(userId: string, listener: Listener) {
    const set = this.listeners.get(userId) ?? new Set<Listener>();
    set.add(listener); this.listeners.set(userId, set);
    return () => { set.delete(listener); if (!set.size) this.listeners.delete(userId); };
  }
  private changed(job: ResearchJob) {
    for (const listener of this.listeners.get(job.userId) ?? []) {
      try { listener({ ...job }); } catch { console.warn("[research] listener unavailable"); }
    }
  }
  start(backend: AgentBackend, request: string) {
    if (!request.trim() || Buffer.byteLength(request) > 12000) throw new Error("Invalid research request");
    const owned = this.list(backend.userId);
    if (this.active(backend.userId) >= 2 || owned.length >= 100) return { status: "limit_reached", message: "At most two running tasks and 100 retained tasks per user. Continue with existing tasks." };
    const job: ResearchJob = { id: randomUUID(), userId: backend.userId, request, state: "running", started: Date.now(), updated: Date.now() };
    this.data.jobs.push(job);
    try { this.persist(); } catch (error) { this.data.jobs = this.data.jobs.filter(j => j !== job); throw error; }
    const abort = new AbortController();
    const timer = setTimeout(() => { this.finish(job, "unconfirmed"); abort.abort(); }, this.deadlineMs);
    timer.unref(); this.running.set(job.id, { abort, timer }); this.changed(job);
    void Promise.resolve().then(() => {
      abort.signal.throwIfAborted();
      return backend.run(request, job.id, abort.signal, "research");
    }).then(result => this.finish(job, "completed", result), () => this.finish(job, "unconfirmed"));
    return { status: "running", task_id: job.id };
  }
  private finish(job: ResearchJob, state: ResearchJob["state"], result?: string) {
    if (job.state !== "running") return;
    const runtime = this.running.get(job.id);
    if (runtime) clearTimeout(runtime.timer);
    this.running.delete(job.id);
    if (state === "completed" && (!result?.trim() || Buffer.byteLength(result) > 16000)) state = "unconfirmed";
    job.state = state; job.updated = Date.now(); job.result = state === "completed" ? result : undefined;
    try { this.persist(); this.changed(job); }
    catch { console.error("[research] Could not persist final result; no completion notification sent"); }
  }
  manage(userId: string, action: "status" | "cancel", id: string, before = Infinity) {
    const jobs = this.data.jobs.filter(j => j.userId === userId && j.started <= before && (id === "all" || j.id === id));
    if (!jobs.length) return { status: "not_found" };
    if (action === "cancel") {
      // Persist cancellation before aborting; a late completion must not resurrect it.
      const active = jobs.filter(j => j.state === "running");
      for (const job of active) { job.state = "cancel_requested"; job.updated = Date.now(); }
      this.persist();
      for (const job of active) {
        const runtime = this.running.get(job.id);
        if (runtime) { clearTimeout(runtime.timer); runtime.abort.abort(); this.running.delete(job.id); }
        this.changed(job);
      }
    }
    return { tasks: jobs.map(j => ({ task_id: j.id, status: j.state, request: j.request, result: j.result,
      elapsed_seconds: Math.floor((Date.now() - j.started) / 1000) })),
      ...(action === "cancel" ? { message: "Stopped waiting and requested cancellation. Remote work may continue; nothing has been undone." } : {}) };
  }
  acknowledge(userId: string, id: string) {
    const job = this.data.jobs.find(j => j.userId === userId && j.id === id);
    if (!job) return false;
    job.acknowledged = true; this.persist(); return true;
  }
  forget(userId: string) {
    this.manage(userId, "cancel", "all");
    this.data.jobs = this.data.jobs.filter(j => j.userId !== userId); this.persist();
  }
  register(device: PushDevice) {
    // A token belongs to only one authenticated owner. Never accept client topics.
    this.data.devices = this.data.devices.filter(d => !(d.token === device.token && d.platform === device.platform && d.environment === device.environment));
    const owned = this.data.devices.filter(d => d.userId === device.userId).sort((a,b) => b.updated-a.updated);
    const evicted = new Set(owned.slice(7));
    this.data.devices = this.data.devices.filter(d => !evicted.has(d));
    this.data.devices.push(device); this.persist();
  }
  devices(userId: string) { return this.data.devices.filter(d => d.userId === userId).map(d => ({ ...d })); }
  removeDevice(device: PushDevice) {
    this.data.devices = this.data.devices.filter(d => !(d.token === device.token && d.environment === device.environment && d.platform === device.platform && d.updated === device.updated)); this.persist();
  }
  pendingNotifications() { return !this.storageAvailable ? [] : this.data.jobs.filter(j => ["completed", "unconfirmed"].includes(j.state) && !j.acknowledged && !j.notified && !this.listeners.get(j.userId)?.size).map(j => ({ ...j })); }
  pendingDevices(userId: string, id: string) {
    const job = this.pendingNotifications().find(j => j.userId === userId && j.id === id);
    return job ? this.devices(userId).filter(d => !job.deliveredTo?.includes(pushDeviceKey(d))) : [];
  }
  delivered(userId: string, id: string, device: PushDevice) {
    const job = this.data.jobs.find(j => j.userId === userId && j.id === id);
    if (!job) return;
    job.deliveredTo = [...new Set([...(job.deliveredTo ?? []), pushDeviceKey(device)])];
    this.persist();
  }
  notified(id: string) { const job = this.data.jobs.find(j => j.id === id); if (job) { job.notified = true; this.persist(); } }
  stop() {
    for (const [id, runtime] of this.running) {
      const job = this.data.jobs.find(j => j.id === id);
      if (job) this.finish(job, "unconfirmed");
      clearTimeout(runtime.timer); runtime.abort.abort();
    }
    this.running.clear(); this.listeners.clear();
  }
}

export function pushDeviceKey(device: PushDevice) { return `${device.environment}:${device.platform}:${device.token}`; }

export function resultEvent(job: ResearchJob) {
  return { type: "chime.research.result", task: { id: job.id, request: Array.from(job.request).slice(0, 500).join(""), status: job.state, result: job.result, started: job.started } };
}
