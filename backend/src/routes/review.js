import { Router } from "express";
import { callApi } from "../db/api.js";
import { ctx, oneOf, text, uuidParam } from "./helpers.js";

export function reviewRoutes({ pool, settings, requireAuth }) {
  const router = Router();

  router.get("/features", requireAuth(), (req, res) => {
    res.json({ simulator: settings.simulator, dedupEnabled: settings.dedupEnabled });
  });

  router.get("/centres", requireAuth(), async (req, res) => {
    const { rows } = await pool.query(
      `SELECT centre_id, centre_code, name, district
         FROM identity.registration_centres WHERE is_active ORDER BY name`,
    );
    res.json(rows);
  });

  router.get("/stats", requireAuth(), async (req, res) => {
    const [row] = await callApi(pool, "api_stats", [req.user.id]);
    res.json(row.api_stats);
  });

  router.get("/citizens", requireAuth(), async (req, res) => {
    const search = text(req.query.search, "search", { max: 80 });
    res.json(await callApi(pool, "api_list_citizens", [req.user.id, search]));
  });

  router.get("/matches", requireAuth(), async (req, res) => {
    const status = oneOf(req.query.status, "status",
      ["pending_review", "confirmed_duplicate", "false_match", "inconclusive", "closed"], { optional: true });
    res.json(await callApi(pool, "api_list_match_cases", [req.user.id, status]));
  });

  router.post("/matches/:id/review", requireAuth(), async (req, res) => {
    const id = uuidParam(req.params.id);
    const b = req.body ?? {};
    const decision = oneOf(b.decision, "decision", ["confirmed_duplicate", "false_match", "inconclusive"]);
    await callApi(pool, "api_review_match",
      [req.user.id, id, decision, text(b.notes, "notes", { max: 300 }), ctx(req).requestId, ctx(req).ip]);
    res.json({ ok: true });
  });

  router.get("/audit", requireAuth(), async (req, res) => {
    const outcome = oneOf(req.query.outcome, "outcome", ["success", "denied", "failure"], { optional: true });
    const search = text(req.query.search, "search", { max: 80 });
    const limit = Math.min(Math.max(Number.parseInt(req.query.limit, 10) || 100, 1), 500);
    res.json(await callApi(pool, "api_list_audit", [req.user.id, outcome, search, limit]));
  });

  return router;
}
