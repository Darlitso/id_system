const MODALITIES = new Set(["fingerprint", "iris"]);

/**
 * Save an encrypted biometric template through the database function
 * identity.api_store_template (migration 004).
 *
 * The backend role has no table privileges, so this is the ONLY write path.
 * The function checks the acting staff member, supersedes any active template
 * for the same citizen + modality, inserts the new one and writes the audit
 * event, all in one transaction. No BEGIN/COMMIT is needed here.
 *
 * `db` is anything with query(sql, params): a pool or a client.
 * Only ciphertext ever leaves this function.
 */
export async function saveTemplate(
  db,
  cipher,
  {
    citizenId,
    modality,
    templateVersion,
    qualityScore = null,
    capturedBy, // acting staff user_id
    template,
    requestId = null,
    sourceIp = null,
  },
) {
  if (!MODALITIES.has(modality)) {
    throw new Error(`Unsupported modality "${modality}"`);
  }
  if (!Buffer.isBuffer(template) || template.length === 0) {
    throw new Error("template must be a non-empty Buffer");
  }

  const { ciphertext, keyId } = cipher.encrypt(template, {
    citizenId,
    modality,
    templateVersion,
  });

  const { rows } = await db.query(
    `SELECT identity.api_store_template($1, $2, $3, $4, $5, $6, $7, $8, $9) AS template_id`,
    [capturedBy, citizenId, modality, ciphertext, keyId, templateVersion, qualityScore, requestId, sourceIp],
  );
  return rows[0].template_id;
}
