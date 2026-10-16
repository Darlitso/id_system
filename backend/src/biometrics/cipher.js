import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

// Blob layout: [1 byte format][12 byte IV][16 byte GCM tag][ciphertext]
const FORMAT_V1 = 1;
const IV_LEN = 12;
const TAG_LEN = 16;
const HEADER_LEN = 1 + IV_LEN + TAG_LEN;

/**
 * Build a keyring from env. DEV ONLY: keys in env are not acceptable for
 * production. In production, fetch/unwrap keys from an external KMS/HSM
 * and keep this same interface.
 */
export function loadKeyring(env = process.env) {
  const activeId = env.BIOMETRIC_ACTIVE_KEY_ID;
  const raw = env.BIOMETRIC_KEYS;
  if (!activeId || !raw) {
    throw new Error("BIOMETRIC_ACTIVE_KEY_ID and BIOMETRIC_KEYS must be set");
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error("BIOMETRIC_KEYS must be valid JSON");
  }
  const keys = new Map();
  for (const [id, b64] of Object.entries(parsed)) {
    const key = Buffer.from(String(b64), "base64");
    if (key.length !== 32) {
      throw new Error(`Biometric key "${id}" must be 32 bytes (base64)`);
    }
    keys.set(id, key);
  }
  if (!keys.has(activeId)) {
    throw new Error("Active biometric key id is not in BIOMETRIC_KEYS");
  }
  return { activeId, keys };
}

// Bind each ciphertext to the record it belongs to, so a blob copied onto
// another citizen/modality/version fails authentication.
function aad({ citizenId, modality, templateVersion }) {
  return Buffer.from(`${citizenId}|${modality}|${templateVersion}`, "utf8");
}

export function createTemplateCipher({ activeId, keys }) {
  return {
    activeKeyId: activeId,

    encrypt(plaintext, context) {
      const iv = randomBytes(IV_LEN);
      const cipher = createCipheriv("aes-256-gcm", keys.get(activeId), iv);
      cipher.setAAD(aad(context));
      const body = Buffer.concat([cipher.update(plaintext), cipher.final()]);
      const blob = Buffer.concat([
        Buffer.from([FORMAT_V1]),
        iv,
        cipher.getAuthTag(),
        body,
      ]);
      return { ciphertext: blob, keyId: activeId };
    },

    decrypt(blob, keyId, context) {
      const key = keys.get(keyId);
      if (!key) {
        throw new Error(`Unknown biometric key id "${keyId}"`);
      }
      if (blob.length < HEADER_LEN || blob[0] !== FORMAT_V1) {
        throw new Error("Unsupported or corrupt template blob");
      }
      const iv = blob.subarray(1, 1 + IV_LEN);
      const tag = blob.subarray(1 + IV_LEN, HEADER_LEN);
      const body = blob.subarray(HEADER_LEN);
      const decipher = createDecipheriv("aes-256-gcm", key, iv);
      decipher.setAAD(aad(context));
      decipher.setAuthTag(tag);
      return Buffer.concat([decipher.update(body), decipher.final()]);
    },
  };
}
