import { createPrivateKey, sign } from "node:crypto";
import { connect } from "node:http2";
import type { BackgroundResearch, PushDevice, ResearchJob } from "./background-research.js";
import { pushDeviceKey } from "./background-research.js";

export type PushOutcome = { status: number; reason?: string };
export type PushSender = (device: PushDevice, job: ResearchJob) => Promise<number | PushOutcome>;
export function notificationPayload(job: ResearchJob) {
  return { aps: { alert: { title: job.state === "completed" ? "Your answer is ready" : "Research update", body: job.state === "completed"
    ? Array.from(job.result ?? "Open Chime to continue.").slice(0, 180).join("")
    : "Research ended without a confirmed answer. Open Chime for details." }, sound: "default", "thread-id": "chime-research" }, research_task_id: job.id };
}
export function apnsFromEnvironment(env: NodeJS.ProcessEnv = process.env): PushSender | undefined {
  if (!env.APNS_KEY_ID && !env.APNS_TEAM_ID && !env.APNS_PRIVATE_KEY) return;
  if (!env.APNS_KEY_ID || !env.APNS_TEAM_ID || !env.APNS_PRIVATE_KEY || !env.APNS_IOS_TOPIC || !env.APNS_WATCH_TOPIC) throw new Error("Incomplete APNs configuration");
  const key = createPrivateKey(env.APNS_PRIVATE_KEY.replace(/\\n/g, "\n"));
  let jwt = "", issued = 0;
  return async (device, job) => {
    const now = Math.floor(Date.now() / 1000);
    if (!jwt || now - issued > 1200) {
      const header = Buffer.from(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })).toString("base64url");
      const claims = Buffer.from(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now })).toString("base64url");
      const content = `${header}.${claims}`;
      jwt = `${content}.${sign("sha256", Buffer.from(content), { key, dsaEncoding: "ieee-p1363" }).toString("base64url")}`; issued = now;
    }
    return new Promise<PushOutcome>((resolve, reject) => {
      const connection = connect(device.environment === "production" ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com");
      const timer = setTimeout(() => finish(new Error("APNs timeout")), 10000);
      let done = false, responseText = "";
      function finish(error?: Error, status?: number) {
        if (done) return; done = true; clearTimeout(timer); connection.destroy();
        if (error) reject(error); else {
          let reason: string | undefined;
          try { reason = JSON.parse(responseText).reason; } catch {}
          resolve({ status: status ?? 503, reason });
        }
      }
      connection.on("error", error => finish(error));
      const request = connection.request({ ":method": "POST", ":path": `/3/device/${device.token}`,
        authorization: `bearer ${jwt}`, "apns-topic": device.platform === "ios" ? env.APNS_IOS_TOPIC : env.APNS_WATCH_TOPIC,
        "apns-push-type": "alert", "apns-priority": "10", "apns-collapse-id": job.id,
        "apns-expiration": String(Math.floor(job.updated / 1000) + 86400) });
      let status = 503;
      request.on("response", headers => { status = Number(headers[":status"]); });
      request.on("data", chunk => { if (responseText.length < 4096) responseText += chunk.toString(); });
      request.on("end", () => finish(undefined, status));
      request.on("error", error => finish(error));
      request.end(JSON.stringify(notificationPayload(job)));
    });
  };
}

/** A saved answer is the source of truth; push is a retryable delivery hint. */
export async function deliverPendingPushes(store: BackgroundResearch, send: PushSender) {
  for (const job of store.pendingNotifications()) {
    if (!store.pendingNotifications().some(current => current.id === job.id && current.userId === job.userId)) continue;
    if (job.updated < Date.now() - 86400000) { store.notified(job.id); continue; }
    const devices = store.pendingDevices(job.userId, job.id);
    if (!devices.length) {
      if (store.devices(job.userId).length) store.notified(job.id);
      continue;
    }
    let finished = true;
    for (const device of devices) {
      // A previous send yielded: ownership, visibility or the job may have changed.
      if (!store.pendingDevices(job.userId, job.id).some(d => pushDeviceKey(d) === pushDeviceKey(device))) continue;
      try {
        const outcome = await send(device, job);
        const status = typeof outcome === "number" ? outcome : outcome.status;
        const invalid = typeof outcome !== "number" && ["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered", "ExpiredToken"].includes(outcome.reason ?? "");
        if (status === 410 || invalid) store.removeDevice(device);
        else if (status === 200) store.delivered(job.userId, job.id, device);
        else if (status !== 200) { finished = false; console.warn(`[push] APNs rejected notification (${status})`); }
      } catch { finished = false; console.warn("[push] Delivery unavailable; saved answer retained"); }
    }
    if (finished && store.pendingNotifications().some(current => current.id === job.id)
        && !store.pendingDevices(job.userId, job.id).length) store.notified(job.id);
  }
}
