import assert from "node:assert/strict";
import { mkdtempSync, rmSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import express from "express";
import { once } from "node:events";
import type { AddressInfo } from "node:net";
import { BackgroundResearch } from "../src/background-research.js";
import { AgentTools } from "../src/agent-tools.js";
import { registerBackgroundRoutes } from "../src/background-routes.js";
import { deliverPendingPushes, notificationPayload } from "../src/push.js";
const tick = () => new Promise(resolve => setImmediate(resolve));
function fixture() {
  const dir = mkdtempSync(join(tmpdir(), "chime-research-"));
  const path = join(dir, "jobs.json");
  const store = new BackgroundResearch(path);
  const runs: { signal: AbortSignal; resolve: (result: string) => void }[] = [];
  const backend = { userId: "alice", run: async (_: string, __: string, signal: AbortSignal) => new Promise<string>(resolve => runs.push({ signal, resolve })) };
  return { dir, path, store, backend, runs, close() { store.stop(); rmSync(dir, { recursive: true, force: true }); } };
}
function startTool(tools: AgentTools) {
  for (const event of [
    { type: "response.created", response: { id: "r" } },
    { type: "response.output_item.done", item: { type: "function_call", call_id: "c", name: "start_openclaw_research", arguments: JSON.stringify({ request: "Look up the answer" }) } },
    { type: "response.completed", response: { id: "r" } },
  ]) tools.handle({ type: "response.event", delegation_id: "d", event });
}

test("closing the voice connection detaches tools while research finishes and survives reload", async () => {
  const f = fixture();
  try {
    const sent: any[] = [];
    const tools = new AgentTools(f.backend, event => sent.push(event), () => {}, f.store);
    startTool(tools); await tick();
    const id = JSON.parse(sent[0].item.output).task_id;
    assert.equal(JSON.parse(readFileSync(f.path, "utf8")).jobs[0].state, "running");
    tools.close(); assert.equal(f.runs[0].signal.aborted, false);
    f.runs[0].resolve("Verified answer"); await tick();
    assert.equal(sent.length, 2, "No events sent to detached voice session");
    assert.equal(f.store.pendingNotifications()[0].id, id);
    const reloaded = new BackgroundResearch(f.path);
    assert.equal(reloaded.list("alice")[0].result, "Verified answer");
    assert.deepEqual(reloaded.list("bob"), []);
    reloaded.stop();
  } finally { f.close(); }
});

test("hold-to-stop requests cancellation and ignores a late remote result", async () => {
  const f = fixture();
  try {
    const tools = new AgentTools(f.backend, () => {}, () => {}, f.store);
    startTool(tools); await tick(); tools.close(true);
    assert.ok(f.runs[0].signal.aborted);
    f.runs[0].resolve("Too late"); await tick();
    assert.equal(f.store.list("alice")[0].state, "cancel_requested");
    assert.deepEqual(f.store.pendingNotifications(), []);
  } finally { f.close(); }
});

test("restarts mark unfinished research unconfirmed without replaying it", async () => {
  const f = fixture();
  try {
    f.store.start(f.backend, "Lookup"); await tick();
    const reopened = new BackgroundResearch(f.path);
    assert.equal(reopened.list("alice")[0].state, "unconfirmed");
    assert.equal(f.runs.length, 1);
    reopened.stop();
  } finally { f.close(); }
});

test("user limits survive reconnection and cancellation before dispatch does not run remote work", async () => {
  const f = fixture();
  try {
    const a = f.store.start(f.backend, "One"); f.store.start(f.backend, "Two");
    assert.equal(f.store.start(f.backend, "Three").status, "limit_reached");
    assert.equal(f.store.manage("bob", "cancel", a.task_id!).status, "not_found");
    f.store.manage("alice", "cancel", a.task_id!); await tick();
    assert.equal(f.runs.length, 1);
    f.store.forget("alice"); f.runs[0].resolve("Late answer"); await tick();
    assert.deepEqual(f.store.list("alice"), []);
  } finally { f.close(); }
});

test("notifications defer while attached, retry temporary failures, and acknowledge once", async () => {
  const f = fixture();
  try {
    f.store.register({ userId: "alice", token: "a".repeat(64), platform: "ios", environment: "production", updated: Date.now() });
    const detach = f.store.subscribe("alice", () => {});
    const job = f.store.start(f.backend, "Lookup"); await tick(); f.runs[0].resolve("🫧 Answer"); await tick();
    let pushes = 0;
    await deliverPendingPushes(f.store, async () => { pushes++; return 200; }); assert.equal(pushes, 0);
    detach();
    await deliverPendingPushes(f.store, async () => { pushes++; return 503; });
    assert.equal(f.store.pendingNotifications().length, 1);
    await deliverPendingPushes(f.store, async (_, answer) => {
      pushes++; assert.equal(notificationPayload(answer).research_task_id, job.task_id); return 200;
    });
    await deliverPendingPushes(f.store, async () => { pushes++; return 200; });
    assert.equal(pushes, 2);
    assert.equal(f.store.acknowledge("bob", job.task_id!), false);
  } finally { f.close(); }
});

test("acknowledged answers need no push and invalidated device tokens are removed", async () => {
  const f = fixture();
  try {
    f.store.register({ userId: "alice", token: "a".repeat(64), platform: "watchos", environment: "sandbox", updated: Date.now() });
    const first = f.store.start(f.backend, "One"); await tick(); f.runs[0].resolve("Answer"); await tick();
    f.store.acknowledge("alice", first.task_id!);
    assert.equal(f.store.pendingNotifications().length, 0);
    f.store.start(f.backend, "Two"); await tick(); f.runs[1].resolve("Answer 2"); await tick();
    await deliverPendingPushes(f.store, async () => 410);
    assert.deepEqual(f.store.devices("alice"), []);
  } finally { f.close(); }
});

test("research HTTP routes authenticate ownership, reject arbitrary push topics, and forget results", async () => {
  const f = fixture(), app = express(); app.use(express.json());
  registerBackgroundRoutes(app, req => req.header("authorization") === "Bearer alice" ? "alice" : req.header("authorization") === "Bearer bob" ? "bob" : null, f.store, true);
  const server = app.listen(0, "127.0.0.1"); await once(server, "listening");
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  try {
    const job = f.store.start(f.backend, "Private lookup"); await tick(); f.runs[0].resolve("Private answer"); await tick();
    assert.equal((await fetch(base + "/v1/research")).status, 401);
    const bob = { authorization: "Bearer bob" };
    assert.deepEqual((await (await fetch(base + "/v1/research", { headers: bob })).json() as any).tasks, []);
    assert.equal((await fetch(base + `/v1/research/${job.task_id}/ack`, { method: "POST", headers: bob })).status, 404);
    assert.equal((await fetch(base + "/v1/push/devices", { method: "PUT", headers: { ...bob, "content-type": "application/json" }, body: JSON.stringify({ token: "not-hex", platform: "ios", environment: "production", topic: "other.app" }) })).status, 400);
    assert.equal((await fetch(base + "/v1/research", { method: "DELETE", headers: { authorization: "Bearer alice" } })).status, 204);
    assert.deepEqual(f.store.list("alice"), []);
  } finally { await new Promise<void>(done => server.close(() => done())); f.close(); }
});


test("a failed journal write prevents dispatch and suppresses undurable completion pushes", async () => {
  const f = fixture();
  try {
    const first = f.store.start(f.backend, "Already running"); await tick();
    rmSync(f.dir, { recursive: true });
    writeFileSync(f.dir, "Block the journal directory");
    assert.throws(() => f.store.start(f.backend, "Must not dispatch"));
    await tick();
    assert.equal(f.runs.length, 1);
    assert.equal(f.store.list("alice").length, 1);
    f.runs[0].resolve("Undurable answer"); await tick();
    assert.deepEqual(f.store.pendingNotifications(), [], "An unsaved result must not promise durable recovery in a push");
    rmSync(f.dir);
    f.store.acknowledge("alice", first.task_id!);
  } finally { f.close(); }
});

test("research deadline aborts remote work and never accepts a late answer", async () => {
  const f = fixture();
  const timed = new BackgroundResearch(join(f.dir, "deadline.json"), 5);
  try {
    timed.start(f.backend, "Slow lookup"); await tick();
    await new Promise(resolve => setTimeout(resolve, 20));
    assert.ok(f.runs[0].signal.aborted);
    assert.equal(timed.list("alice")[0].state, "unconfirmed");
    f.runs[0].resolve("Late answer"); await tick();
    assert.equal(timed.list("alice")[0].result, undefined);
    assert.equal(timed.pendingNotifications()[0].state, "unconfirmed");
  } finally { timed.stop(); f.close(); }
});

test("delayed stop cancellation cannot affect a newer conversation's research", async () => {
  const f = fixture();
  try {
    const first = f.store.start(f.backend, "First conversation"); await tick();
    const cutoff = f.store.list("alice")[0].started;
    await new Promise(resolve => setTimeout(resolve, 5));
    const second = f.store.start(f.backend, "New conversation"); await tick();
    f.store.manage("alice", "cancel", "all", cutoff);
    assert.equal(f.store.list("alice").find(j => j.id === first.task_id)?.state, "cancel_requested");
    assert.equal(f.store.list("alice").find(j => j.id === second.task_id)?.state, "running");
    assert.equal(f.runs[1].signal.aborted, false);
    f.runs[1].resolve("Still needed"); await tick();
    assert.equal(f.store.list("alice")[1].result, "Still needed");
  } finally { f.close(); }
});

test("blank, oversized, and failed remote answers remain unconfirmed", async () => {
  const f = fixture();
  try {
    for (const result of ["  ", "🫧".repeat(4001)]) {
      f.store.start(f.backend, "Lookup"); await tick(); f.runs.at(-1)!.resolve(result); await tick();
      assert.equal(f.store.list("alice").at(-1)!.state, "unconfirmed");
      assert.equal(f.store.list("alice").at(-1)!.result, undefined);
    }
    f.store.start({ userId: "alice", run: async () => { throw new Error("remote unavailable"); } }, "Lookup");
    await tick();
    assert.equal(f.store.list("alice").at(-1)!.state, "unconfirmed");
    assert.equal(f.store.active("alice"), 0);
  } finally { f.close(); }
});

test("registering a device under a new owner removes the old owner's access", () => {
  const f = fixture();
  try {
    const device = { userId: "alice", token: "a".repeat(64), platform: "ios" as const, environment: "production" as const, updated: Date.now() };
    f.store.register(device);
    f.store.register({ ...device, userId: "bob", updated: device.updated + 1 });
    assert.deepEqual(f.store.devices("alice"), []);
    assert.equal(f.store.devices("bob").length, 1);
    f.store.removeDevice(device);
    assert.equal(f.store.devices("bob").length, 1, "An in-flight rejection for an old registration must not delete its replacement");
    const reloaded = new BackgroundResearch(f.path);
    assert.deepEqual(reloaded.devices("alice"), []);
    assert.equal(reloaded.devices("bob").length, 1);
    reloaded.stop();
  } finally { f.close(); }
});

test("push transport failures retain results, while bad-token reasons remove unusable devices", async () => {
  const f = fixture();
  try {
    f.store.register({ userId: "alice", token: "a".repeat(64), platform: "ios", environment: "production", updated: Date.now() });
    f.store.start(f.backend, "Lookup"); await tick(); f.runs[0].resolve("🫧".repeat(200)); await tick();
    await deliverPendingPushes(f.store, async () => { throw new Error("network unavailable"); });
    assert.equal(f.store.pendingNotifications().length, 1);
    const payload = notificationPayload(f.store.list("alice")[0]);
    assert.equal(Array.from(payload.aps.alert.body).length, 180);
    assert.equal(payload.aps.alert.body, "🫧".repeat(180), "The alert must not split surrogate pairs");
    await deliverPendingPushes(f.store, async () => ({ status: 400, reason: "DeviceTokenNotForTopic" }));
    assert.deepEqual(f.store.devices("alice"), []);
    assert.equal(f.store.list("alice")[0].result, "🫧".repeat(200));
    assert.deepEqual(f.store.pendingNotifications(), []);
  } finally { f.close(); }
});

test("push fan-out rechecks token ownership after each awaited delivery", async () => {
  const f = fixture();
  try {
    const first = { userId: "alice", token: "a".repeat(64), platform: "ios" as const, environment: "production" as const, updated: Date.now() };
    const second = { ...first, token: "b".repeat(64), platform: "watchos" as const };
    f.store.register(first); f.store.register(second);
    f.store.start(f.backend, "Private lookup"); await tick(); f.runs[0].resolve("Private Alice answer"); await tick();
    const recipients: string[] = [];
    await deliverPendingPushes(f.store, async device => {
      recipients.push(device.token);
      if (device.token === first.token) {
        await tick();
        f.store.register({ ...second, userId: "bob", updated: second.updated + 1 });
      }
      return 200;
    });
    assert.deepEqual(recipients, [first.token], "A token reassigned during the previous APNs request must not receive the former owner's answer");
  } finally { f.close(); }
});

for (const action of ["acknowledge", "forget"] as const) {
  test(`push fan-out respects ${action} while another delivery is in flight`, async () => {
    const f = fixture();
    try {
      const device = { userId: "alice", token: "a".repeat(64), platform: "ios" as const, environment: "production" as const, updated: Date.now() };
      f.store.register(device); f.store.register({ ...device, token: "b".repeat(64) });
      const job = f.store.start(f.backend, "Lookup"); await tick(); f.runs[0].resolve("Answer"); await tick();
      let deliveries = 0;
      await deliverPendingPushes(f.store, async () => {
        deliveries++;
        await tick();
        if (action === "acknowledge") f.store.acknowledge("alice", job.task_id!);
        else f.store.forget("alice");
        return 200;
      });
      assert.equal(deliveries, 1, "Acknowledged or forgotten answers must not be sent to remaining recipients");
    } finally { f.close(); }
  });
}

test("successful device deliveries persist across restarts while only failed devices retry", async () => {
  const f = fixture();
  try {
    const first = { userId: "alice", token: "a".repeat(64), platform: "ios" as const, environment: "production" as const, updated: Date.now() };
    const second = { ...first, token: "b".repeat(64), platform: "watchos" as const };
    f.store.register(first); f.store.register(second);
    f.store.start(f.backend, "Lookup"); await tick(); f.runs[0].resolve("Answer"); await tick();
    const initial: string[] = [];
    await deliverPendingPushes(f.store, async device => { initial.push(device.token); return device.token === first.token ? 200 : 503; });
    assert.deepEqual(initial, [first.token, second.token]);
    const reloaded = new BackgroundResearch(f.path);
    try {
      const retried: string[] = [];
      await deliverPendingPushes(reloaded, async device => { retried.push(device.token); return 200; });
      assert.deepEqual(retried, [second.token], "The accepted phone push must not repeat because the Watch temporarily failed");
      assert.deepEqual(reloaded.pendingNotifications(), []);
    } finally { reloaded.stop(); }
  } finally { f.close(); }
});
