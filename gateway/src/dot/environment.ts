import { createHash } from "node:crypto";
import type express from "express";
import { createDotOAuth } from "./auth.js";
import { DotBridge } from "./bridge.js";
import { DotStore } from "./store.js";
import { registerDotRoutes } from "./routes.js";
import { createCallbackPost } from "./webhook.js";

/** Opt-in, one owner/connection prototype. OAuth and multi-tenant credential
 * provisioning belong at a later integration boundary, not in this scaffold. */
export function dotFromEnvironment(app: express.Express, tokens: Map<string, string>, serviceToken?: string, env = process.env) {
  if (env.DOT_BRIDGE_ENABLED !== "true") return undefined;
  const owner = env.DOT_USER_ID;
  const token = env.DOT_PLUGIN_TOKEN;
  const oauth = env.DOT_AUTH_MODE === "oauth";
  const path = env.DOT_STORE_PATH;
  const hosts = (env.DOT_CALLBACK_HOSTS ?? "").split(",").map(s => s.trim()).filter(Boolean);
  if (!owner || !path || !hosts.length || ![...tokens.values()].includes(owner) ||
      (!oauth && (env.DOT_AUTH_MODE !== "local-test" || !token || Buffer.byteLength(token) < 32 || tokens.has(token) || token === serviceToken)) ||
      hosts.some(h => !/^[a-z0-9]+(?:[.-][a-z0-9]+)*\.[a-z]{2,}$/.test(h))) throw new Error("Invalid dot bridge configuration; see docs/chatgpt-dot-bridge.md");
  const auth = oauth ? createDotOAuth({ issuer: env.DOT_OAUTH_ISSUER ?? "", jwksURL: env.DOT_OAUTH_JWKS_URL ?? "", resource: env.DOT_OAUTH_RESOURCE ?? "", subject: env.DOT_OAUTH_SUBJECT ?? "" }) : token!;
  const identity = oauth ? [env.DOT_OAUTH_ISSUER, env.DOT_OAUTH_RESOURCE, env.DOT_OAUTH_SUBJECT] : [token];
  const allowedHosts = new Set(hosts);
  const store = new DotStore(path);
  const bridge = new DotBridge(store, { owner, principal: createHash("sha256").update(JSON.stringify([owner, ...identity])).digest("hex"),
    allowedHosts, post: createCallbackPost(allowedHosts), authorized: () => env.DOT_BRIDGE_ENABLED === "true" && env.DOT_PLUGIN_TOKEN === token && [...tokens.values()].includes(owner) });
  registerDotRoutes(app, bridge, auth, tokens, serviceToken);
  const tick = () => { void bridge.deliver().catch(() => console.error("[dot] Delivery unavailable; inspect bridge configuration and journal")); };
  const timer = setInterval(tick, 1000); timer.unref(); tick();
  const close = () => { clearInterval(timer); bridge.close(); store.close(); };
  process.once("exit", close);
  return { bridge, close };
}
