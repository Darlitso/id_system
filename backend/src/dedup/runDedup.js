import { callApi } from "../db/api.js";
import { findCandidates } from "./candidates.js";
import { matcherFor } from "./matchers.js";

/**
 * Search the stored gallery for people who may already be enrolled.
 * Candidates are recorded as match cases for HUMAN review; nothing is auto-confirmed.
 * The gallery is released encrypted by the database (and audited) and decrypted here only.
 */
export async function runDedup({ db, cipher, actorId, enrolmentId, citizenId, modality, template, reviewScore, ctx }) {
  const rows = await callApi(db, "api_get_gallery", [actorId, modality, citizenId, ctx.requestId, ctx.ip]);
  const gallery = [];
  for (const r of rows) {
    try {
      const plain = cipher.decrypt(r.g_ciphertext, r.g_key_id, {
        citizenId: r.g_citizen_id,
        modality,
        templateVersion: r.g_version,
      });
      gallery.push({ citizenId: r.g_citizen_id, modality, template: plain });
    } catch {
      // An undecryptable entry is skipped and counted, never allowed to abort the search.
    }
  }
  const candidates = findCandidates({
    probe: { citizenId, modality, template },
    gallery,
    matcher: matcherFor(modality),
    reviewScore,
  });
  for (const c of candidates) {
    await callApi(db, "api_record_match_case", [
      actorId, enrolmentId, c.candidateCitizenId, modality, c.matchScore, ctx.requestId, ctx.ip,
    ]);
  }
  return { compared: gallery.length, skipped: rows.length - gallery.length, flagged: candidates.length };
}
