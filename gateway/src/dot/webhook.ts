import dns from "node:dns/promises";
import https from "node:https";
import { isIP } from "node:net";
import ipaddr from "ipaddr.js";
import { Webhook } from "standardwebhooks";

export type CallbackResponse = { status: number; body: string };
export type CallbackPost = (url: string, body: string, headers: Record<string, string>, signal: AbortSignal) => Promise<CallbackResponse>;

export function callbackURL(raw: unknown, allowedHosts: ReadonlySet<string>): URL {
  if (typeof raw !== "string" || raw.length > 2048) throw new Error("Invalid callback URL");
  const url = new URL(raw);
  if (url.protocol !== "https:" || url.username || url.password || url.hash || url.port ||
      isIP(url.hostname.replace(/^\[|\]$/g, "")) || !allowedHosts.has(url.hostname)) {
    throw new Error("Callback must use HTTPS on an explicitly allowed DNS hostname");
  }
  return url;
}

export function publicAddress(address: string): boolean {
  try { return ipaddr.parse(address).range() === "unicast"; } catch { return false; }
}

export function signingKey(secret: unknown): string {
  if (typeof secret !== "string" || !/^whsec_(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(secret)) throw new Error("Invalid signing key");
  const bytes = Buffer.from(secret.slice(6), "base64");
  if (bytes.length < 24 || bytes.length > 64) throw new Error("Invalid signing key length");
  return secret;
}

export function signedHeaders(id: string, subscriptionId: string, body: string, secret: string, oldSecret?: string) {
  const date = new Date();
  return {
    "Content-Type": "application/json",
    "webhook-id": id,
    "webhook-timestamp": String(Math.floor(date.getTime() / 1000)),
    "webhook-signature": [secret, ...(oldSecret ? [oldSecret] : [])].map(key => new Webhook(key).sign(id, date, body)).join(" "),
    "X-MCP-Subscription-Id": subscriptionId,
  };
}

/** Resolve for EVERY request, reject mixed public/private answers, and pin the socket
 * lookup to that answer. TLS still verifies the original hostname. No proxy,
 * redirects, reusable socket, or second DNS lookup can bypass this check. */
export function createCallbackPost(allowedHosts: ReadonlySet<string>): CallbackPost {
  return async (raw, body, headers, signal) => {
    const url = callbackURL(raw, allowedHosts);
    signal.throwIfAborted();
    // DNS itself is raced against the deadline; no connection starts after abort.
    const addresses = await new Promise<Awaited<ReturnType<typeof resolveAll>>>((resolve, reject) => {
      const abort = () => reject(signal.reason);
      signal.addEventListener("abort", abort, { once: true });
      resolveAll(url.hostname).then(resolve, reject).finally(() => signal.removeEventListener("abort", abort));
    });
    signal.throwIfAborted();
    if (!addresses.length || addresses.some(a => !publicAddress(a.address))) throw new Error("Non-public callback address");
    const chosen = addresses[0];
    return new Promise((resolve, reject) => {
      const req = https.request(url, {
        method: "POST", headers, agent: false, signal,
        lookup: (_hostname, options, callback) => {
          if (options.all) callback(null, [chosen]);
          else callback(null, chosen.address, chosen.family);
        },
      }, res => {
        const chunks: Buffer[] = [];
        let bytes = 0;
        res.on("data", (chunk: Buffer) => {
          bytes += chunk.length;
          if (bytes > 16384) { req.destroy(new Error("Callback response too large")); return; }
          chunks.push(chunk);
        });
        res.on("error", reject);
        res.on("end", () => resolve({ status: res.statusCode ?? 0, body: Buffer.concat(chunks).toString("utf8") }));
      });
      req.on("error", reject);
      req.end(body);
    });
  };
}
function resolveAll(host: string) { return dns.lookup(host, { all: true, verbatim: true }); }
