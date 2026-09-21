import assert from "node:assert/strict";
import { test } from "node:test";
import { AgentTools } from "../src/agent-tools.js";
import { createOpenClawBackend, openClawFromEnvironment } from "../src/openclaw.js";

const options = { baseURL: "https://agent.example/v1", token: "operator-secret", userId: "alice" };
const result = { status: "completed", output: [{ type: "message", content: [{ type: "output_text", text: "Ready." }] }] };
const tick = () => new Promise(resolve => setImmediate(resolve));

test("OpenClaw pins routing and stable identity, with credentials only in headers", async () => {
  const requests: any[] = [];
  const backend = createOpenClawBackend({ ...options, accessClientId: "cf-id", accessClientSecret: "cf-secret", fetch: async (url, init) => {
    requests.push({ url: String(url), ...init, body: JSON.parse(init!.body as string) });
    return Response.json(result);
  }});
  for (const id of ["one", "two"]) assert.equal(await backend.run("What is my project status?", id, new AbortController().signal), "Ready.");
  assert.equal(requests[0].url, "https://agent.example/v1/responses");
  assert.equal(requests[0].redirect, "error");
  assert.equal(requests[0].headers.Authorization, "Bearer operator-secret");
  assert.equal(requests[0].headers["CF-Access-Client-Secret"], "cf-secret");
  assert.equal(requests[0].body.model, "openclaw/main");
  assert.match(requests[0].body.user, /^chime-[a-f0-9]{32}$/);
  assert.equal(requests[0].body.user, requests[1].body.user);
  assert.equal(JSON.stringify(requests[0].body).includes("operator-secret"), false);
});

test("connector is optional but partial or unsafe configuration fails closed", () => {
  assert.equal(openClawFromEnvironment({}), undefined);
  for (const baseURL of ["http://agent.example/v1", "https://user:pass@agent.example/v1", "https://agent.example/v1?token=secret"]) {
    assert.throws(() => createOpenClawBackend({ ...options, baseURL }));
  }
  assert.throws(() => createOpenClawBackend({ ...options, accessClientId: "unpaired" }));
  assert.throws(() => openClawFromEnvironment({ OPENCLAW_BASE_URL: options.baseURL }));
});

for (const [name, response] of [
  ["unauthorized", () => new Response("private error", { status: 401 })],
  ["login page", () => new Response("<html>login</html>")],
  ["incomplete", () => Response.json({ ...result, status: "incomplete" })],
  ["client tool", () => Response.json({ ...result, output: [{ type: "function_call" }] })],
  ["oversized", () => new Response("x".repeat(256001))],
] as const) test(`rejects ${name} responses`, async () => {
  const backend = createOpenClawBackend({ ...options, fetch: async () => response() });
  await assert.rejects(backend.run("hello", "id", new AbortController().signal));
});

test("concurrent requests are rejected and cancellation reaches fetch", async () => {
  let started!: () => void;
  const ready = new Promise<void>(resolve => { started = resolve; });
  const backend = createOpenClawBackend({ ...options, fetch: async (_, init) => {
    started();
    return new Promise<Response>((_, reject) => init!.signal!.addEventListener("abort", () => reject(new Error("aborted")), { once: true }));
  }});
  const controller = new AbortController();
  const first = backend.run("hello", "one", controller.signal);
  const rejected = assert.rejects(first, /aborted/);
  await ready;
  await assert.rejects(backend.run("again", "two", controller.signal), /still handling/);
  controller.abort();
  await rejected;
});

const envelope = (type: string, extra: object = {}) => ({ type: "response.event", delegation_id: "delegation", event: { type, ...extra } });
const call = (id = "call", args = { request: "Read my project status" }, name = "ask_openclaw") => envelope("response.output_item.done", { item: { type: "function_call", call_id: id, name, arguments: JSON.stringify(args) } });
const created = () => envelope("response.created", { response: { id: "response" } });
const completed = () => envelope("response.completed", { response: { id: "response", output: [] } });

test("tool execution waits for completion, deduplicates calls and resumes Responses", async () => {
  const requests: string[] = [], sent: any[] = [];
  const tools = new AgentTools({ userId: "alice", run: async request => { requests.push(request); return "Ready"; } }, event => sent.push(event));
  tools.handle(created()); tools.handle(call()); tools.handle(call());
  assert.equal(requests.length, 0);
  tools.handle(completed()); tools.handle(completed());
  await tick();
  assert.deepEqual(requests, ["Read my project status"]);
  assert.equal(sent.length, 2);
  assert.equal(sent[0].item.call_id, "call");
  assert.equal(JSON.parse(sent[0].item.output).status, "completed");
  assert.deepEqual(sent[1], { type: "response.create" });
});

test("failed responses never execute and closing cancels pending work without speaking", async () => {
  let calls = 0, finish!: (text: string) => void, signal: AbortSignal | undefined;
  const sent: any[] = [];
  const tools = new AgentTools({ userId: "alice", run: async (_, __, abort) => {
    calls++; signal = abort;
    return new Promise(resolve => { finish = resolve; });
  } }, event => sent.push(event));
  tools.handle(created()); tools.handle(call());
  tools.handle(envelope("response.failed", { response: { id: "response" } }));
  tools.handle(completed());
  assert.equal(calls, 0);
  tools.handle(created()); tools.handle(call("second")); tools.handle(completed());
  tools.close();
  assert.equal(signal!.aborted, true);
  finish("Done"); await tick();
  assert.deepEqual(sent, []);
});

test("unknown tools, model-selected routing and agent failures return unconfirmed without retries", async () => {
  for (const item of [call("one", { request: "hello" }, "unknown"), call("two", { request: "hello", userId: "bob" } as any), call("three")]) {
    let calls = 0;
    const sent: any[] = [];
    const tools = new AgentTools({ userId: "alice", run: async () => { calls++; throw new Error("private secret"); } }, event => sent.push(event));
    tools.handle(created()); tools.handle(item); tools.handle(completed()); await tick();
    assert.equal(calls, item.event.item.call_id === "three" ? 1 : 0);
    assert.equal(JSON.parse(sent[0].item.output).status, "unconfirmed");
    assert.equal(JSON.stringify(sent).includes("private secret"), false);
  }
});
