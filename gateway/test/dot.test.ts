import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { once } from "node:events";
import { createServer } from "node:http";
import dns from "node:dns/promises";
import https from "node:https";
import { EventEmitter } from "node:events";
import express from "express";
import { Webhook } from "standardwebhooks";
import { DotBridge } from "../src/dot/bridge.js";
import { DotStore } from "../src/dot/store.js";
import { registerDotRoutes } from "../src/dot/routes.js";
import { dotFromEnvironment } from "../src/dot/environment.js";
import { callbackURL, createCallbackPost, publicAddress, signedHeaders, signingKey, type CallbackPost } from "../src/dot/webhook.js";

const secret = "whsec_" + Buffer.alloc(32, 3).toString("base64");
const hosts = new Set(["receiver.example.com"]);
const params = (changes = {}) => ({ name: "message.created", arguments: { channel_id: "watch" }, delivery: { mode: "webhook", url: "https://receiver.example.com/callback", secret }, cursor: null, ...changes });
const stopParams = () => ({ name: "message.created", arguments: { channel_id: "watch" }, delivery: { mode: "webhook", url: "https://receiver.example.com/callback" } });
function fixture(t: any, post?: CallbackPost) {
  const dir = mkdtempSync(join(tmpdir(), "chime-dot-"));
  const path = join(dir, "dot.json");
  let store = new DotStore(path);
  let now = Date.now();
  let authorized = true;
  const calls: { data: any; body: string; headers: Record<string, string> }[] = [];
  const options = { owner: "alice", principal: "connection-a", allowedHosts: hosts, now: () => now, authorized: () => authorized,
    post: post ?? (async (_url, body, headers) => {
      const data = JSON.parse(body);
      new Webhook(secret).verify(body, headers);
      calls.push({ data, body, headers });
      return { status: 200, body: JSON.stringify(data.type === "verification" ? { challenge: data.challenge } : {}) };
    }) };
  let bridge = new DotBridge(store, options);
  t.after(() => { bridge.close(); store.close(); rmSync(dir, { recursive: true, force: true }); });
  return { get bridge() { return bridge; }, get store() { return store; }, path, calls,
    advance(ms: number) { now += ms; }, revoke() { authorized = false; },
    restart() { bridge.close(); store.close(); store = new DotStore(path); bridge = new DotBridge(store, options); },
  };
}

test("signed verified text roundtrip, exact duplicate IDs and out-of-order replies survive restart", async t => {
  const f = fixture(t);
  const subscription = await f.bridge.subscribe("alice", params());
  assert.equal((await f.bridge.subscribe("alice", params())).id, subscription.id);
  assert.equal(f.calls.length, 1, "unchanged verified callback is cached");
  const first = f.bridge.enqueue("alice", "operation-one", "First question");
  const second = f.bridge.enqueue("alice", "operation-two", "Second question");
  assert.equal(f.bridge.enqueue("alice", "operation-one", "First question").id, first.id);
  assert.throws(() => f.bridge.enqueue("alice", "operation-one", "Different"), /already used/);
  f.restart();
  await f.bridge.deliver();
  assert.deepEqual(f.calls.slice(1).map(c => c.data.eventId), ["evt_" + first.id, "evt_" + second.id]);
  assert.equal(f.bridge.read("alice", first.id).state, "pending", "callback receipt is not a dot answer");
  f.bridge.reply("alice", second.id, "Second answer");
  f.bridge.reply("alice", first.id, "First answer");
  f.restart();
  assert.equal(f.bridge.read("alice", second.id).reply, "Second answer");
  assert.equal(f.bridge.reply("alice", first.id, "First answer").status, "replied");
  assert.throws(() => f.bridge.reply("alice", first.id, "Conflicting answer"), /finalized/);
  await f.bridge.deliver();
  assert.equal(f.calls.length, 3);
  assert.equal(statSync(f.path).mode & 0o777, 0o600);
});

test("cancel, deadline and unsubscribe reject late replies and never resurrect messages", async t => {
  const f = fixture(t); await f.bridge.subscribe("alice", params());
  const a = f.bridge.enqueue("alice", "a", "Cancel me");
  f.bridge.cancel("alice", a.id); f.bridge.cancel("alice", a.id);
  assert.throws(() => f.bridge.reply("alice", a.id, "Late"), /finalized/);
  const b = f.bridge.enqueue("alice", "b", "Timeout");
  f.advance(600001);
  assert.equal(f.bridge.read("alice", b.id).state, "expired");
  assert.throws(() => f.bridge.reply("alice", b.id, "Late"), /finalized/);
  const c = f.bridge.enqueue("alice", "c", "Unsubscribe");
  f.bridge.unsubscribe("alice", stopParams()); f.bridge.unsubscribe("alice", stopParams());
  await f.bridge.subscribe("alice", params());
  assert.equal(f.bridge.read("alice", c.id).state, "cancelled");
  assert.throws(() => f.bridge.reply("alice", c.id, "Late"), /no longer active/);
  await f.bridge.deliver(); assert.equal(f.calls.length, 2, "no application data sent");
});

test("owner isolation, revocation, no subscription and filter validation", async t => {
  const f = fixture(t);
  assert.throws(() => f.bridge.enqueue("alice", "a", "No subscription"), /subscribe/);
  await assert.rejects(f.bridge.subscribe("bob", params()), /unauthorized/);
  await assert.rejects(f.bridge.subscribe("alice", params({ arguments: { channel_id: "other" } })), /Unsupported/);
  await assert.rejects(f.bridge.subscribe("alice", params({ cursor: "replay" })), /Unsupported/);
  await f.bridge.subscribe("alice", params());
  const m = f.bridge.enqueue("alice", "a", "Private");
  assert.throws(() => f.bridge.read("bob", m.id), /unauthorized/);
  assert.throws(() => f.bridge.reply("bob", m.id, "Spoof"), /unauthorized/);
  f.revoke();
  await assert.rejects(f.bridge.deliver(), /unauthorized/);
  assert.throws(() => f.bridge.reply("alice", m.id, "Revoked"), /unauthorized/);
  assert.equal(f.calls.length, 1);
});

test("persistent bounded retries keep the same event and fresh signatures; no immediate retry", async t => {
  const calls: { body: string; headers: any }[] = [];
  const f = fixture(t, async (_url, body, headers) => {
    const data = JSON.parse(body);
    if (data.type === "verification") return { status: 200, body: JSON.stringify({ challenge: data.challenge }) };
    new Webhook(secret).verify(body, headers); calls.push({ body, headers }); return { status: 503, body: "" };
  });
  await f.bridge.subscribe("alice", params());
  const m = f.bridge.enqueue("alice", "a", "Retry");
  await f.bridge.deliver(); await f.bridge.deliver(); assert.equal(calls.length, 1);
  f.restart();
  for (let i = 0; i < 5; i++) { f.advance(60000); await f.bridge.deliver(); }
  assert.equal(calls.length, 5);
  assert.ok(calls.every(c => c.body === calls[0].body));
  assert.equal(f.bridge.read("alice", m.id).state, "delivery_failed");
});

for (const status of [410, 413, 403]) test(`HTTP ${status} stops delivery retries`, async t => {
  let count = 0;
  const f = fixture(t, async (_url, body) => {
    const data = JSON.parse(body);
    if (data.type === "verification") return { status: 200, body: JSON.stringify({ challenge: data.challenge }) };
    count++; return { status, body: "" };
  });
  await f.bridge.subscribe("alice", params());
  const m = f.bridge.enqueue("alice", "a", "Failure");
  await f.bridge.deliver(); f.advance(60000); await f.bridge.deliver();
  assert.equal(count, 1); assert.equal(f.bridge.read("alice", m.id).state, "delivery_failed");
});

test("failed callback verification cannot install a subscription or send application data", async t => {
  const f = fixture(t, async () => ({ status: 200, body: '{"challenge":"wrong"}' }));
  await assert.rejects(f.bridge.subscribe("alice", params()), (e: any) => e.code === -32015 && e.reason === "challenge_failed");
  assert.equal(f.store.snapshot().subscriptions.length, 0);
  assert.throws(() => f.bridge.enqueue("alice", "a", "No callback"), /subscribe/);
});

test("finite TTL, restart refresh, one destination, and signing-key rotation", async t => {
  const replacement = "whsec_" + Buffer.alloc(32, 4).toString("base64");
  let headers: Record<string, string> = {};
  let eventBody = "";
  const f = fixture(t, async (_url, body, received) => {
    const data = JSON.parse(body);
    if (data.type !== "verification") { headers = received; eventBody = body; }
    return { status: 200, body: JSON.stringify({ challenge: data.challenge }) };
  });
  const s = await f.bridge.subscribe("alice", params({ ttlMs: 1000 }));
  f.restart();
  const refresh = await f.bridge.subscribe("alice", params({ delivery: { ...params().delivery, secret: replacement } }));
  assert.equal(s.id, refresh.id);
  await assert.rejects(f.bridge.subscribe("alice", params({ delivery: { ...params().delivery, url: "https://receiver.example.com/other" } })), /One dot/);
  f.bridge.enqueue("alice", "a", "Rotated"); await f.bridge.deliver();
  new Webhook(secret).verify(eventBody, headers); new Webhook(replacement).verify(eventBody, headers);
  f.advance(86400001);
  assert.throws(() => f.bridge.enqueue("alice", "b", "Expired"), /subscribe/);
  await f.bridge.subscribe("alice", params({ ttlMs: null }));
  assert.notEqual(f.store.snapshot().subscriptions[0].expires, null);
  await assert.rejects(f.bridge.subscribe("alice", params({ ttlMs: -1 })), /ttlMs/);
});

test("adapter roundtrip uses operation correlation, abort persists cancellation, research rejected", async t => {
  const f = fixture(t); await f.bridge.subscribe("alice", params());
  const adapter = f.bridge.backend();
  const abort = new AbortController();
  const result = adapter.run("Question", "adapter", abort.signal);
  const m = f.store.snapshot().messages[0];
  f.bridge.reply("alice", m.id, "Answer");
  assert.equal(await result, "Answer");
  const pending = adapter.run("Cancel", "cancel", abort.signal);
  abort.abort(); await assert.rejects(pending);
  assert.equal(f.store.snapshot().messages[1].state, "cancelled");
  await assert.rejects(adapter.run("research", "r", new AbortController().signal, "research"), /unsupported/);
});

test("single writer, corrupt journal and capacity limits fail closed", async t => {
  const f = fixture(t);
  assert.throws(() => new DotStore(f.path), /already open/);
  await f.bridge.subscribe("alice", params());
  for (let i = 0; i < 16; i++) f.bridge.enqueue("alice", String(i), "Bounded");
  assert.throws(() => f.bridge.enqueue("alice", "17", "Too many"), /capacity/);
  assert.throws(() => f.bridge.enqueue("alice", "large", "🌍".repeat(4000)), /Invalid/);
  const corrupt = f.path + ".corrupt"; writeFileSync(corrupt, '{"version":999}');
  assert.throws(() => new DotStore(corrupt), /Invalid dot journal/);
});

test("callback policy rejects private IPv4/IPv6, alternate representations, credentials and redirects", async () => {
  for (const ip of ["127.0.0.1", "10.0.0.1", "169.254.169.254", "100.64.0.1", "192.0.2.1", "224.1.1.1", "::1", "::", "fc00::1", "fe80::1", "::ffff:8.8.8.8", "2001:db8::1", "2002:7f00:1::"]) assert.equal(publicAddress(ip), false, ip);
  assert.equal(publicAddress("8.8.8.8"), true); assert.equal(publicAddress("2606:4700:4700::1111"), true);
  for (const url of ["http://receiver.example.com", "https://receiver.example.com:8443", "https://user:pass@receiver.example.com", "https://receiver.example.com/#x", "https://localhost", "https://127.1", "https://2130706433", "https://[::1]", "https://receiver.example.com.attacker.org"]) assert.throws(() => callbackURL(url, hosts));
  for (const value of ["no", "whsec_AAAA", "whsec_" + Buffer.alloc(65).toString("base64")]) assert.throws(() => signingKey(value));
  assert.equal(signingKey(secret), secret);
});

test("callback transport pins each connection to checked DNS, rejects mixed addresses and never redirects", async t => {
  let lookups = 0; let requests = 0;
  const lookup = t.mock.method(dns, "lookup", async () => { lookups++; return [{ address: "8.8.8.8", family: 4 }]; });
  t.mock.method(https, "request", (url: URL, options: any, callback: any) => {
    requests++; assert.equal(url.hostname, "receiver.example.com"); assert.equal(options.agent, false);
    options.lookup(url.hostname, { all: false }, (err: any, address: string, family: number) => { assert.equal(err, null); assert.equal(address, "8.8.8.8"); assert.equal(family, 4); });
    const req = new EventEmitter() as any;
    req.end = () => {
      const res = new EventEmitter() as any; res.statusCode = 302; res.headers = { location: "http://127.0.0.1/secret" };
      callback(res); res.emit("end");
    };
    return req;
  });
  const post = createCallbackPost(hosts);
  for (let i = 0; i < 2; i++) assert.equal((await post("https://receiver.example.com/callback", "{}", {}, AbortSignal.timeout(1000))).status, 302);
  assert.equal(lookups, 2); assert.equal(requests, 2);
  lookup.mock.mockImplementation(async () => [{ address: "8.8.8.8", family: 4 }, { address: "127.0.0.1", family: 4 }]);
  await assert.rejects(post("https://receiver.example.com/callback", "{}", {}, AbortSignal.timeout(1000)), /Non-public/);
  assert.equal(requests, 2);
});

test("tampered body, wrong signing key and stale webhook signatures fail verification", () => {
  const body = JSON.stringify({ eventId: "evt_test", data: {} });
  const headers = signedHeaders("evt_test", "sub_test", body, secret);
  const verifier = new Webhook(secret);
  verifier.verify(body, headers);
  assert.throws(() => verifier.verify(body + " ", headers));
  assert.throws(() => new Webhook("whsec_" + Buffer.alloc(32, 8).toString("base64")).verify(body, headers));
  assert.throws(() => verifier.verify(body, { ...headers, "webhook-timestamp": "1" }));
});

test("HTTP MCP 2.0 and device surfaces complete a roundtrip with disjoint credentials", async t => {
  const f = fixture(t); const app = express(); app.use(express.json());
  const tokens = new Map([["device-a", "alice"], ["device-b", "bob"]]);
  registerDotRoutes(app, f.bridge, "plugin-only", tokens);
  const server = createServer(app); server.listen(0, "127.0.0.1"); await once(server, "listening");
  t.after(() => new Promise<void>(resolve => { server.closeAllConnections(); server.close(() => resolve()); }));
  const base = `http://127.0.0.1:${(server.address() as any).port}`;
  const call = async (method: string, params: any = {}, token = "plugin-only", extra: any = {}) => fetch(base + "/mcp/dot", {
    method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}`, "MCP-Protocol-Version": "2026-07-28", "Mcp-Method": method, ...(method === "tools/call" ? { "Mcp-Name": params.name } : {}), ...extra },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params: { ...params, _meta: { "io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {} } } }),
  });
  assert.equal((await call("server/discover", {}, "device-a")).status, 401);
  assert.equal((await call("server/discover", {}, "plugin-only", { Origin: "https://evil.example" })).status, 403);
  assert.equal((await call("server/discover", {}, "plugin-only", { "Mcp-Method": "tools/call" })).status, 400);
  assert.deepEqual((await (await call("server/discover")).json()).result.supportedVersions, ["2026-07-28"]);
  assert.equal((await (await call("events/list")).json()).result.events[0].name, "message.created");
  assert.equal((await (await call("tools/list")).json()).result.tools.length, 2);
  assert.equal((await call("unknown")).status, 404);
  const sub = await (await call("events/subscribe", params())).json(); assert.ok(sub.result.id);
  const submit = (token: string, body: object) => fetch(base + "/v1/dot/messages", { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}`, "x-user-id": "alice" }, body: JSON.stringify(body) });
  for (const token of ["plugin-only", "device-b", "service-token"]) assert.equal((await submit(token, { operation_id: "a", text: "Hello" })).status, 401);
  assert.equal((await submit("device-a", { operation_id: "a", text: "Hello", owner: "bob" })).status, 400);
  const sent = await (await submit("device-a", { operation_id: "a", text: "Hello" })).json();
  await f.bridge.deliver();
  const read = await (await call("tools/call", { name: "read_message", arguments: { message_id: sent.message_id } })).json();
  assert.equal(JSON.parse(read.result.content[0].text).text, "Hello");
  const reply = await (await call("tools/call", { name: "send_reply", arguments: { message_id: sent.message_id, text: "Hi" } })).json();
  assert.equal(reply.result.isError, false);
  const answer = await (await fetch(base + "/v1/dot/messages/" + sent.message_id, { headers: { Authorization: "Bearer device-a" } })).json();
  assert.equal(answer.reply, "Hi");
  tokens.delete("device-a");
  assert.equal((await submit("device-a", { operation_id: "a", text: "Hello" })).status, 401);
});

test("environment is disabled by default and refuses shared/invalid credentials", () => {
  const tokens = new Map([["device-token", "alice"]]);
  assert.equal(dotFromEnvironment(express(), tokens, undefined, {}), undefined);
  assert.throws(() => dotFromEnvironment(express(), tokens, undefined, { DOT_BRIDGE_ENABLED: "true" }), /configuration/);
});

test("OAuth resource server verifies signature, issuer, resource, subject, access-token type, scope and expiry", async () => {
  const { generateKeyPair, SignJWT, exportJWK, createLocalJWKSet } = await import("jose");
  const { createDotOAuth } = await import("../src/dot/auth.js");
  const { publicKey, privateKey } = await generateKeyPair("ES256");
  const config = { issuer: "https://issuer.example.com", jwksURL: "https://issuer.example.com/jwks", resource: "https://chime.example.com/mcp/dot", subject: "bound-subject" };
  const auth = createDotOAuth(config, createLocalJWKSet({ keys: [await exportJWK(publicKey)] }));
  const now = Math.floor(Date.now() / 1000);
  const sign = (claims = {}, typ = "at+jwt") => new SignJWT({ iss: config.issuer, aud: config.resource, sub: config.subject, scope: "chime:dot", iat: now, exp: now + 240, ...claims })
    .setProtectedHeader({ alg: "ES256", typ }).sign(privateKey);
  const expires = await auth.authenticate("Bearer " + await sign());
  assert.ok(expires && expires <= Date.now() + 300000);
  for (const changes of [{ iss: "https://other.example.com" }, { aud: "other" }, { sub: "another-owner" }, { scope: "openid" }, { exp: now - 1 }, { iat: now + 3600 }, { exp: now + 3600 }]) {
    assert.equal(await auth.authenticate("Bearer " + await sign(changes)), undefined);
  }
  assert.equal(await auth.authenticate("Bearer " + await sign({}, "JWT")), undefined, "ID tokens cannot impersonate access tokens");
  assert.equal(await auth.authenticate("Bearer not-a-jwt"), undefined);
});

test("verification cache has an absolute deadline and OAuth grants cannot be extended by callback latency", async t => {
  const f = fixture(t); await f.bridge.subscribe("alice", params());
  f.advance(240000); await f.bridge.subscribe("alice", params());
  assert.equal(f.calls.length, 1);
  f.advance(61000); await f.bridge.subscribe("alice", params());
  assert.equal(f.calls.length, 2);
  await assert.rejects(f.bridge.subscribe("alice", params(), Date.now() - 1), /grant expired/);
});

test("unsubscribe during verification prevents a delayed callback from recreating the subscription", async t => {
  let complete!: () => void;
  const f = fixture(t, async (_url, body) => {
    await new Promise<void>(resolve => { complete = resolve; });
    return { status: 200, body: JSON.stringify({ challenge: JSON.parse(body).challenge }) };
  });
  const subscribing = f.bridge.subscribe("alice", params());
  f.bridge.unsubscribe("alice", stopParams()); complete();
  await assert.rejects(subscribing);
  assert.equal(f.store.snapshot().subscriptions.length, 0);
});

test("disk failure never acknowledges a message or dispatches an undurable event", async t => {
  const f = fixture(t); await f.bridge.subscribe("alice", params());
  const before = readFileSync(f.path, "utf8");
  rmSync(f.path);
  // A directory at the journal destination forces atomic rename to fail.
  const { mkdirSync } = await import("node:fs"); mkdirSync(f.path);
  assert.throws(() => f.bridge.enqueue("alice", "a", "Cannot persist"));
  await assert.rejects(f.bridge.deliver(), /unavailable/);
  assert.equal(f.calls.length, 1);
  rmSync(f.path, { recursive: true }); writeFileSync(f.path, before);
});

test("OAuth HTTP discovery challenges and subscription lifetime honor verified access grant", async t => {
  const f = fixture(t); const app = express(); app.use(express.json());
  const expires = Date.now() + 2000;
  const auth = { resource: "https://chime.example.com/mcp/dot", issuer: "https://issuer.example.com", authenticate: async (header: string | undefined) => header?.startsWith("Bearer ") ? expires : undefined };
  registerDotRoutes(app, f.bridge, auth, new Map([["device-a", "alice"]]), "service-token");
  const server = createServer(app); server.listen(0, "127.0.0.1"); await once(server, "listening");
  t.after(() => new Promise<void>(resolve => { server.closeAllConnections(); server.close(() => resolve()); }));
  const base = `http://127.0.0.1:${(server.address() as any).port}`;
  const metadata = await (await fetch(base + "/.well-known/oauth-protected-resource/mcp/dot")).json();
  assert.equal(metadata.resource, auth.resource); assert.deepEqual(metadata.authorization_servers, [auth.issuer]);
  const unauthorized = await fetch(base + "/mcp/dot", { method: "POST" });
  assert.equal(unauthorized.status, 401); assert.match(unauthorized.headers.get("www-authenticate")!, /oauth-protected-resource/);
  for (const token of ["device-a", "service-token"]) {
    assert.equal((await fetch(base + "/mcp/dot", { method: "POST", headers: { Authorization: `Bearer ${token}` } })).status, 401);
  }
  const response = await fetch(base + "/mcp/dot", { method: "POST", headers: {
    "Content-Type": "application/json", Authorization: "Bearer verified-test-access-token", "MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "events/subscribe",
  }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "events/subscribe", params: { ...params(), _meta: { "io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {} } } }) });
  const subscription = await response.json();
  assert.ok(subscription.result, JSON.stringify(subscription));
  assert.ok(Date.parse(subscription.result.refreshBefore) <= expires);
});
