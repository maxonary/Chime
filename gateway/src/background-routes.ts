import type express from "express";
import type { BackgroundResearch } from "./background-research.js";
export function registerBackgroundRoutes(app: express.Express, userFromRequest: (req: express.Request) => string | null, store?: BackgroundResearch, pushConfigured = false) {
  app.use("/v1/research", (req, res, next) => {
    if (!userFromRequest(req)) { res.sendStatus(401); return; }
    if (!store) { res.status(503).json({ error: "Background research is not configured" }); return; }
    next();
  });
  app.get("/v1/research", (req, res) => { res.json({ tasks: store!.list(userFromRequest(req)!).slice(-20), notifications: pushConfigured }); });
  app.post("/v1/research/:id/ack", (req, res) => {
    res.sendStatus(store!.acknowledge(userFromRequest(req)!, String(req.params.id)) ? 204 : 404);
  });
  app.post("/v1/research/cancel", (req, res) => {
    if (typeof req.body?.task_id !== "string") { res.sendStatus(400); return; }
    const before = req.body.before_ms === undefined ? Infinity : Number(req.body.before_ms);
    if (Number.isNaN(before) || before <= 0) { res.sendStatus(400); return; }
    res.json(store!.manage(userFromRequest(req)!, "cancel", req.body.task_id, before));
  });
  app.delete("/v1/research", (req, res) => { store!.forget(userFromRequest(req)!); res.sendStatus(204); });
  app.put("/v1/push/devices", (req, res) => {
    const userId = userFromRequest(req);
    if (!userId) { res.sendStatus(401); return; }
    if (!store || !pushConfigured) { res.sendStatus(503); return; }
    const { token, platform, environment } = req.body ?? {};
    if (Object.keys(req.body ?? {}).some(key => !["token", "platform", "environment"].includes(key)) || typeof token !== "string" || !/^[a-f0-9]{32,512}$/.test(token) || !["ios", "watchos"].includes(platform) || !["production", "sandbox"].includes(environment)) { res.sendStatus(400); return; }
    store.register({ token, platform, environment, userId, updated: Date.now() }); res.sendStatus(204);
  });
}
