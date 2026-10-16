import test from "node:test";
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { createTemplateCipher } from "../src/biometrics/cipher.js";
import { saveTemplate } from "../src/biometrics/templateStore.js";

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

function fakeClient({ failOn } = {}) {
  const calls = [];
  return {
    calls,
    async query(sql, params) {
      calls.push({ sql: sql.trim().split(/\s+/)[0], params });
      if (failOn && sql.includes(failOn)) throw new Error("boom");
      return { rows: [{ template_id: "t-1" }] };
    },
  };
}

test("supersedes then inserts inside a transaction, storing ciphertext only", async () => {
  const client = fakeClient();
  const id = await saveTemplate(client, cipher, input);
  assert.equal(id, "t-1");
  assert.deepEqual(client.calls.map((c) => c.sql), ["BEGIN", "UPDATE", "INSERT", "COMMIT"]);
  const insertParams = client.calls[2].params;
  assert.ok(Buffer.isBuffer(insertParams[2]));
  assert.notDeepEqual(insertParams[2], input.template);
  assert.equal(insertParams[3], "k1");
});

test("rolls back on failure", async () => {
  const client = fakeClient({ failOn: "INSERT" });
  await assert.rejects(() => saveTemplate(client, cipher, input), /boom/);
  assert.equal(client.calls.at(-1).sql, "ROLLBACK");
});

test("rejects bad modality / empty template", async () => {
  await assert.rejects(() => saveTemplate(fakeClient(), cipher, { ...input, modality: "face" }));
  await assert.rejects(() => saveTemplate(fakeClient(), cipher, { ...input, template: Buffer.alloc(0) }));
});
