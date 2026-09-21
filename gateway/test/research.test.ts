import assert from "node:assert/strict";
import { test } from "node:test";
import { ResearchTasks } from "../src/research-tasks.js";
import { AgentTools } from "../src/agent-tools.js";
import { createOpenClawBackend } from "../src/openclaw.js";
const tick = () => new Promise(resolve => setImmediate(resolve));

function fixture(timing?: { deadlineMs: number; progressMs: number }) {
  const runs: { signal: AbortSignal; resolve: (text: string) => void }[] = [];
  const sent: any[] = [], counts: number[] = [];
  const tasks = new ResearchTasks({ userId: "alice", run: async (_, __, signal, mode) => {
    assert.equal(mode, "research");
    return new Promise<string>(resolve => runs.push({ signal, resolve }));
  } }, event => sent.push(event), count => counts.push(count), timing);
  return { tasks, runs, sent, counts };
}

test("two independent research tasks acknowledge immediately and retain full results", async () => {
  const f = fixture();
  try {
    const first = f.tasks.start("Research one"), second = f.tasks.start("Research two");
    assert.equal(first.status, "running");
    assert.notEqual(first.task_id, second.task_id);
    assert.equal(f.tasks.start("Third").status, "limit_reached");
    await tick();
    assert.equal(f.runs.length, 2);
    const result = "🫧 Evidence. ".repeat(100);
    f.runs[1].resolve(result); await tick();
    assert.deepEqual(f.counts, [1, 2, 1]);
    assert.equal(f.sent.length, 1);
    assert.equal(f.sent[0].type, "session.commentary.append");
    assert.equal(f.sent[0].delegation_id, null);
    assert.ok(Buffer.byteLength(f.sent[0].content) <= 480);
    assert.ok(!f.sent[0].content.includes("�"));
    assert.equal(f.tasks.manage("status", second.task_id!).tasks![0].result, result);
    assert.equal(f.tasks.manage("status", first.task_id!).tasks![0].status, "running");
  } finally { f.tasks.close(); }
});

test("cancelling one task leaves another running, suppresses late results, and scopes IDs to the call", async () => {
  const f = fixture(), other = fixture();
  try {
    const first = f.tasks.start("One"), second = f.tasks.start("Two");
    await tick();
    assert.equal(other.tasks.manage("cancel", first.task_id!).status, "not_found");
    const cancelled = f.tasks.manage("cancel", first.task_id!);
    assert.equal(cancelled.tasks![0].status, "cancel_requested");
    assert.match(cancelled.message!, /may continue/);
    assert.equal(f.runs[0].signal.aborted, true);
    assert.equal(f.runs[1].signal.aborted, false);
    f.runs[0].resolve("Stale"); f.runs[1].resolve("Verified"); await tick();
    assert.equal(f.sent.length, 1);
    assert.ok(f.sent[0].content.includes(second.task_id));
    assert.deepEqual(f.counts, [1, 2, 1, 0]);
  } finally { f.tasks.close(); other.tasks.close(); }
});

test("closing aborts all tasks and prevents late announcements", async () => {
  const f = fixture();
  f.tasks.start("One"); f.tasks.start("Two"); await tick();
  f.tasks.close();
  for (const run of f.runs) { assert.ok(run.signal.aborted); run.resolve("Late"); }
  await tick();
  assert.deepEqual(f.sent, []);
  assert.throws(() => f.tasks.start("Closed"));
});

test("progress is quiet and timeout releases state even if a backend ignores cancellation", async () => {
  const f = fixture({ deadlineMs: 30, progressMs: 5 });
  try {
    const task = f.tasks.start("Slow"); await new Promise(resolve => setTimeout(resolve, 60));
    assert.equal(f.sent[0].type, "session.thinking.append");
    assert.equal(f.sent[1].type, "session.commentary.append");
    assert.equal(f.tasks.manage("status", task.task_id!).tasks![0].status, "unconfirmed");
    assert.ok(f.runs[0].signal.aborted);
    f.runs[0].resolve("Too late"); await tick();
    assert.equal(f.sent.length, 2);
    assert.deepEqual(f.counts, [1, 0]);
  } finally { f.tasks.close(); }
});

test("research uses separate OpenClaw sessions while normal actions keep their stable session", async () => {
  const bodies: any[] = [], signals: AbortSignal[] = [];
  const backend = createOpenClawBackend({ baseURL: "https://agent.example/v1", token: "secret", userId: "alice", fetch: async (_, init) => {
    bodies.push(JSON.parse(init!.body as string)); signals.push(init!.signal!);
    return new Promise<Response>((_, reject) => init!.signal!.addEventListener("abort", () => reject(new Error("abort")), { once: true }));
  } });
  const controllers = Array.from({ length: 3 }, () => new AbortController());
  const requests = [backend.run("One", "one", controllers[0].signal, "research"),
    backend.run("Two", "two", controllers[1].signal, "research"), backend.run("Who are you?", "identity", controllers[2].signal)];
  const settled = Promise.allSettled(requests);
  assert.equal(bodies.length, 3);
  assert.equal(new Set(bodies.map(body => body.user)).size, 3);
  assert.match(bodies[0].instructions, /research task/);
  await assert.rejects(backend.run("Third", "three", controllers[0].signal, "research"), /already running/);
  controllers[0].abort(); await tick();
  assert.ok(signals[0].aborted); assert.ok(!signals[1].aborted);
  controllers[1].abort(); controllers[2].abort(); await settled;
});

test("background tools resume the Responses turn before a lookup completes, and deduplicate starts", async () => {
  let resolve!: (text: string) => void, calls = 0;
  const sent: any[] = [];
  const tools = new AgentTools({ userId: "alice", run: async () => { calls++; return new Promise<string>(done => { resolve = done; }); } }, event => sent.push(event));
  const handle = (event: object) => tools.handle({ type: "response.event", delegation_id: "d", event });
  try {
    handle({ type: "response.created", response: { id: "r" } });
    const item = { type: "function_call", call_id: "c", name: "start_openclaw_research", arguments: JSON.stringify({ request: "Research this" }) };
    handle({ type: "response.output_item.done", item }); handle({ type: "response.output_item.done", item });
    handle({ type: "response.completed", response: { id: "r" } });
    assert.equal(JSON.parse(sent[0].item.output).status, "running");
    assert.equal(sent[1].type, "response.create");
    await tick(); assert.equal(calls, 1);
    resolve("Done"); await tick();
    assert.equal(sent[2].type, "session.commentary.append");
  } finally { tools.close(); }
});

test("task retention is bounded and cancellation before dispatch never starts remote work", async () => {
  const f = fixture();
  try {
    const first = f.tasks.start("Cancel before dispatch");
    f.tasks.manage("cancel", first.task_id!);
    await tick(); assert.equal(f.runs.length, 0);
    for (let index = 1; index < 8; index++) {
      f.tasks.start(`Lookup ${index}`); await tick();
      f.runs.at(-1)!.resolve("Done"); await tick();
    }
    assert.equal(f.tasks.start("Too many").status, "limit_reached");
    assert.equal(f.tasks.manage("status", "all").tasks!.length, 8);
  } finally { f.tasks.close(); }
});

test("management tools reject model-selected routing without starting any backend request", async () => {
  const sent: any[] = [];
  let calls = 0;
  const tools = new AgentTools({ userId: "alice", run: async () => { calls++; return "Unexpected"; } }, event => sent.push(event));
  try {
    for (const [index, args] of [
      { action: "cancel", task_id: "all", userId: "bob" },
      { action: "delete", task_id: "all" },
    ].entries()) {
      for (const event of [
        { type: "response.created", response: { id: `r${index}` } },
        { type: "response.output_item.done", item: { type: "function_call", call_id: `c${index}`, name: "manage_openclaw_research", arguments: JSON.stringify(args) } },
        { type: "response.completed", response: { id: `r${index}` } },
      ]) tools.handle({ type: "response.event", delegation_id: `d${index}`, event });
    }
    assert.equal(calls, 0);
    assert.equal(sent.filter(event => event.item && JSON.parse(event.item.output).status === "unconfirmed").length, 2);
  } finally { tools.close(); }
});

for (const outcome of ["rejected", "blank", "oversized"]) test(`research reports ${outcome} results as unconfirmed without retrying`, async () => {
  const sent: any[] = [], counts: number[] = [];
  let calls = 0;
  const tasks = new ResearchTasks({ userId: "alice", run: async () => {
    calls++;
    if (outcome === "rejected") throw new Error("private backend detail");
    return outcome === "blank" ? "   " : "x".repeat(16001);
  } }, event => sent.push(event), active => counts.push(active));
  try {
    const task = tasks.start("Look this up"); await tick();
    const status = tasks.manage("status", task.task_id!).tasks![0];
    assert.equal(status.status, "unconfirmed");
    assert.equal(status.result, undefined);
    assert.equal(calls, 1);
    assert.deepEqual(counts, [1, 0]);
    assert.equal(sent.length, 1);
    assert.match(sent[0].content, /without a confirmed result/);
    assert.ok(!JSON.stringify(sent).includes("private backend detail"));
  } finally { tasks.close(); }
});
