import { Router } from "express";
import { saveTemplate } from "../biometrics/templateStore.js";
import { noisyCopy, randomQuality, randomTemplate, TEMPLATE_BYTES } from "../biometrics/simulator.js";
import { callApi, callScalar, HttpError } from "../db/api.js";
import { runDedup } from "../dedup/runDedup.js";
import { ctx, isoDate, oneOf, text, uuidParam } from "./helpers.js";

const MODALITIES = ["fingerprint", "iris"];

export function enrolmentRoutes({ pool, cipher, settings, requireAuth }) {
  const router = Router();

  router.get("/enrolments", requireAuth(), async (req, res) => {
    const status = oneOf(req.query.status, "status",
      ["draft", "submitted", "matching", "flagged", "approved", "rejected", "cancelled"], { optional: true });
    res.json(await callApi(pool, "api_list_enrolments", [req.user.id, status]));
  });

  router.post("/enrolments", requireAuth(), async (req, res) => {
    const b = req.body ?? {};
    const centreId = uuidParam(b.centreId ?? req.user.centreId, "centreId");
    const rows = await callApi(pool, "api_submit_enrolment", [
      req.user.id,
      centreId,
      text(b.fullName, "fullName", { required: true }),
      isoDate(b.dateOfBirth, "dateOfBirth"),
      text(b.placeOfBirth, "placeOfBirth"),
      oneOf(b.gender, "gender", ["male", "female"], { optional: true }),
      text(b.village, "village"),
      text(b.district, "district"),
      text(b.chief, "chief"),
      text(b.address, "address", { max: 300 }),
      ctx(req).requestId,
      ctx(req).ip,
    ]);
    res.status(201).json({ citizenId: rows[0].new_citizen_id, enrolmentId: rows[0].new_enrolment_id });
  });

  // Capture one biometric: encrypt it, store it through the database function, then
  // (when enabled) search for possible duplicates.
  router.post("/enrolments/:id/biometrics", requireAuth(), async (req, res) => {
    const enrolmentId = uuidParam(req.params.id);
    const b = req.body ?? {};
    const modality = oneOf(b.modality, "modality", MODALITIES);
    const c = ctx(req);

    const [enrolment] = await callApi(pool, "api_get_enrolment", [req.user.id, enrolmentId]);
    if (!enrolment) throw new HttpError(404, "not_found", "Enrolment not found");
    if (!["submitted", "matching", "flagged"].includes(enrolment.status)) {
      throw new HttpError(409, "conflict", "This enrolment is closed");
    }

    let template;
    let quality;
    if (typeof b.template === "string") {
      template = Buffer.from(b.template, "base64");
      if (template.length !== TEMPLATE_BYTES) {
        throw new HttpError(400, "invalid_request", `template must be ${TEMPLATE_BYTES} bytes (base64)`);
      }
      quality = typeof b.quality === "number" ? b.quality : null;
    } else if (b.simulate && settings.simulator) {
      quality = randomQuality();
      template = randomTemplate();
      if (b.simulate.sameAs) {
        // Simulate a person who is already on the register presenting again.
        const sameAs = uuidParam(b.simulate.sameAs, "simulate.sameAs");
        const gallery = await callApi(pool, "api_get_gallery",
          [req.user.id, modality, enrolment.citizen_id, c.requestId, c.ip]);
        const row = gallery.find((g) => g.g_citizen_id === sameAs);
        if (!row) throw new HttpError(404, "not_found", "That person has no stored template for this modality");
        const original = cipher.decrypt(row.g_ciphertext, row.g_key_id,
          { citizenId: row.g_citizen_id, modality, templateVersion: row.g_version });
        template = noisyCopy(original);
      }
    } else {
      throw new HttpError(400, "invalid_request", "Provide a template (base64) from the scanner");
    }

    const templateId = await saveTemplate(pool, cipher, {
      citizenId: enrolment.citizen_id,
      modality,
      templateVersion: "v1",
      qualityScore: quality,
      capturedBy: req.user.id,
      template,
      requestId: c.requestId,
      sourceIp: c.ip,
    });

    let dedup = null;
    if (settings.dedupEnabled) {
      dedup = await runDedup({
        db: pool, cipher, actorId: req.user.id, enrolmentId, citizenId: enrolment.citizen_id,
        modality, template, reviewScore: settings.reviewScore, ctx: c,
      });
    }
    // Officers are told only THAT a possible duplicate was flagged, never who it might be.
    res.status(201).json({
      templateId, modality, quality,
      duplicateSearch: dedup ? { ran: true, compared: dedup.compared, flagged: dedup.flagged > 0 } : { ran: false },
    });
  });

  router.post("/enrolments/:id/decision", requireAuth(), async (req, res) => {
    const enrolmentId = uuidParam(req.params.id);
    const b = req.body ?? {};
    const decision = oneOf(b.decision, "decision", ["approve", "reject"]);
    const identityNumber = await callScalar(pool, "api_decide_enrolment", [
      req.user.id, enrolmentId, decision, text(b.reason, "reason", { max: 300 }), ctx(req).requestId, ctx(req).ip,
    ]);
    res.json({ decision, identityNumber: identityNumber ?? null });
  });

  return router;
}
