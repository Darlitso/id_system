import { Router } from "express";
import { noisyCopy, randomTemplate, TEMPLATE_BYTES } from "../biometrics/simulator.js";
import { callApi, HttpError } from "../db/api.js";
import { matcherFor } from "../dedup/matchers.js";
import { ctx, ID_NUMBER_RE, oneOf } from "./helpers.js";

// Service-provider check: does this person match the fingerprint on record for this number?
// The provider receives a result (and the name only on success), never any biometric data.
export function verifyRoutes({ pool, cipher, settings, requireAuth }) {
  const router = Router();

  router.post("/verify", requireAuth(), async (req, res) => {
    const b = req.body ?? {};
    if (typeof b.identityNumber !== "string" || !ID_NUMBER_RE.test(b.identityNumber)) {
      throw new HttpError(400, "invalid_request", "identityNumber must look like 123456/10/1");
    }
    const c = ctx(req);
    const record = (citizenId, result, reason) =>
      callApi(pool, "api_record_verification", [req.user.id, citizenId, result, reason, c.requestId, c.ip]);

    const [holder] = await callApi(pool, "api_verify_lookup", [req.user.id, b.identityNumber, c.requestId, c.ip]);
    if (!holder) {
      await record(null, "not_verified", "UNKNOWN_NUMBER");
      return res.json({ result: "not_verified" });
    }
    if (holder.v_status !== "active") {
      await record(holder.v_citizen_id, "revoked", `CITIZEN_${holder.v_status}`.toUpperCase());
      return res.json({ result: "revoked" });
    }
    if (!holder.v_ciphertext) {
      await record(holder.v_citizen_id, "error", "NO_TEMPLATE");
      return res.json({ result: "error" });
    }

    const stored = cipher.decrypt(holder.v_ciphertext, holder.v_key_id, {
      citizenId: holder.v_citizen_id, modality: "fingerprint", templateVersion: holder.v_version,
    });
    let probe;
    if (typeof b.probe === "string") {
      probe = Buffer.from(b.probe, "base64");
      if (probe.length !== TEMPLATE_BYTES) throw new HttpError(400, "invalid_request", "probe has the wrong size");
    } else if (b.simulate && settings.simulator) {
      probe = oneOf(b.simulate, "simulate", ["genuine", "impostor"]) === "genuine" ? noisyCopy(stored) : randomTemplate();
    } else {
      throw new HttpError(400, "invalid_request", "Provide the fingerprint captured at the counter (probe)");
    }

    const score = matcherFor("fingerprint")(probe, stored);
    const verified = score >= settings.verifyMinScore;
    await record(holder.v_citizen_id, verified ? "verified" : "not_verified", verified ? null : "BIOMETRIC_MISMATCH");
    res.json({
      result: verified ? "verified" : "not_verified",
      ...(verified ? { name: holder.v_name } : {}),
      ...(settings.simulator ? { score } : {}), // scores are only exposed in the dev simulator
    });
  });

  return router;
}
