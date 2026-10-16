import test from "node:test";
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { createTemplateCipher, loadKeyring } from "../src/biometrics/cipher.js";

const keyring = () => ({
  activeId: "k1",
  keys: new Map([
    ["k1", randomBytes(32)],
    ["k0", randomBytes(32)],
  ]),
});
const ctx = { citizenId: "c-1", modality: "iris", templateVersion: "v1" };

test("round trip", () => {
  const c = createTemplateCipher(keyring());
  const plain = randomBytes(256);
  const { ciphertext, keyId } = c.encrypt(plain, ctx);
  assert.equal(keyId, "k1");
  assert.deepEqual(c.decrypt(ciphertext, keyId, ctx), plain);
});

test("ciphertext differs per call (random IV)", () => {
  const c = createTemplateCipher(keyring());
  const plain = randomBytes(32);
  assert.notDeepEqual(c.encrypt(plain, ctx).ciphertext, c.encrypt(plain, ctx).ciphertext);
});

test("tampering is detected", () => {
  const c = createTemplateCipher(keyring());
  const { ciphertext, keyId } = c.encrypt(randomBytes(64), ctx);
  ciphertext[ciphertext.length - 1] ^= 1;
  assert.throws(() => c.decrypt(ciphertext, keyId, ctx));
});

test("blob cannot be moved to another citizen/modality/version", () => {
  const c = createTemplateCipher(keyring());
  const { ciphertext, keyId } = c.encrypt(randomBytes(64), ctx);
  for (const other of [
    { ...ctx, citizenId: "c-2" },
    { ...ctx, modality: "fingerprint" },
    { ...ctx, templateVersion: "v2" },
  ]) {
    assert.throws(() => c.decrypt(ciphertext, keyId, other));
  }
});

test("unknown key id is rejected", () => {
  const c = createTemplateCipher(keyring());
  const { ciphertext } = c.encrypt(randomBytes(16), ctx);
  assert.throws(() => c.decrypt(ciphertext, "nope", ctx), /Unknown biometric key/);
});

test("old key still decrypts after rotation", () => {
  const kr = keyring();
  const oldCipher = createTemplateCipher({ ...kr, activeId: "k0" });
  const { ciphertext, keyId } = oldCipher.encrypt(Buffer.from("x"), ctx);
  const newCipher = createTemplateCipher(kr);
  assert.equal(newCipher.decrypt(ciphertext, keyId, ctx).toString(), "x");
});

test("loadKeyring validates input", () => {
  assert.throws(() => loadKeyring({}), /must be set/);
  assert.throws(
    () => loadKeyring({ BIOMETRIC_ACTIVE_KEY_ID: "a", BIOMETRIC_KEYS: '{"a":"AAAA"}' }),
    /32 bytes/,
  );
  const ok = loadKeyring({
    BIOMETRIC_ACTIVE_KEY_ID: "a",
    BIOMETRIC_KEYS: JSON.stringify({ a: randomBytes(32).toString("base64") }),
  });
  assert.equal(ok.activeId, "a");
});
