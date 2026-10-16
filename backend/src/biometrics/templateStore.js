const MODALITIES = new Set(["fingerprint", "iris"]);

/**
 * Save an encrypted biometric template. Runs in ONE transaction on the given
 * client: any existing active template for the same citizen+modality is marked
 * superseded, then the new one is inserted as active.
 *
 * `client` must be a checked-out pg client (pool.connect()), not the pool.
 * NOTE: untested against a live database so far; see test/templateStore.test.js
 * for the query-order test with a fake client.
 */
export async function saveTemplate(
  client,
  cipher,
  { citizenId, modality, templateVersion, qualityScore, capturedBy, template },
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

  await client.query("BEGIN");
  try {
    await client.query(
      `UPDATE identity.biometric_templates
          SET status = 'superseded'
        WHERE citizen_id = $1 AND modality = $2 AND status = 'active'`,
      [citizenId, modality],
    );
    const { rows } = await client.query(
      `INSERT INTO identity.biometric_templates
         (citizen_id, modality, template_ciphertext, encryption_key_id,
          template_version, quality_score, captured_by)
       VALUES ($1, $2, $3, $4, $5, $6, $7)
       RETURNING template_id`,
      [citizenId, modality, ciphertext, keyId, templateVersion, qualityScore, capturedBy],
    );
    await client.query("COMMIT");
    return rows[0].template_id;
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  }
}
