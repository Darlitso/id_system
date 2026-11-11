import test from "node:test";
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { createTemplateCipher } from "../biometrics/cipher.js";
import { saveTemplate } from "../biometrics/templateStore.js";

const cipher = createTemplateCipher({
  activeId: "k1",
  keys: new Map([["k1", randomBytes(32)]]),
});
const input = {
  citizenId: "c-1",
  modality: "iris",
  templateVersion: "v1",
  qualityScore: 90,
  capturedBy: "u-1",
  template: randomBytes(64),
};

function fakeDb({ fail } = {}) {
  const calls = [];
  return {
    calls,
    async query(sql, params) {
      calls.push({ sql: sql.trim(), params });
      if (fail) throw new Error("boom");
      return { rows: [{ template_id: "t-1" }] };
    },
  };
}

test("stores through the database function, sending ciphertext only", async () => {
  const db = fakeDb();
  const id = await saveTemplate(db, cipher, { ...input, requestId: "r-1", sourceIp: "10.0.0.1" });
  assert.equal(id, "t-1");
  assert.equal(db.calls.length, 1);
  assert.match(db.calls[0].sql, /identity\.api_store_template/);
  const [actor, citizen, modality, ciphertext, keyId, version, quality, requestId, ip] = db.calls[0].params;
  assert.equal(actor, input.capturedBy);
  assert.equal(citizen, input.citizenId);
  assert.equal(modality, "iris");
  assert.ok(Buffer.isBuffer(ciphertext));
  assert.notDeepEqual(ciphertext, input.template);
  assert.equal(keyId, "k1");
  assert.equal(version, "v1");
  assert.equal(quality, 90);
  assert.equal(requestId, "r-1");
  assert.equal(ip, "10.0.0.1");
});

test("never sends the plaintext template to the database", async () => {
  const db = fakeDb();
  await saveTemplate(db, cipher, input);
  for (const p of db.calls[0].params) {
    if (Buffer.isBuffer(p)) assert.ok(!p.equals(input.template));
  }
});

test("propagates database errors (e.g. permission denied)", async () => {
  await assert.rejects(() => saveTemplate(fakeDb({ fail: true }), cipher, input), /boom/);
});

test("rejects bad modality / empty template before touching the database", async () => {
  const db = fakeDb();
  await assert.rejects(() => saveTemplate(db, cipher, { ...input, modality: "face" }));
  await assert.rejects(() => saveTemplate(db, cipher, { ...input, template: Buffer.alloc(0) }));
  assert.equal(db.calls.length, 0);
});
