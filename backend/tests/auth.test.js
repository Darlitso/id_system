import assert from "node:assert/strict";
import test from "node:test";
import { burnPasswordCheck, hashPassword, verifyPassword } from "../src/auth/password.js";
import { createRateLimiter } from "../src/auth/rateLimit.js";
import { signToken, verifyToken } from "../src/auth/token.js";

const SECRET = "x".repeat(40);

test("password: hash verifies, wrong password and bad formats do not", async () => {
  const hash = await hashPassword("correct horse battery");
  assert.match(hash, /^scrypt\$/);
  assert.equal(await verifyPassword("correct horse battery", hash), true);
  assert.equal(await verifyPassword("wrong password!!", hash), false);
  assert.equal(await verifyPassword("anything", "FAKE_HASH_DEV_ONLY"), false);
  assert.equal(await verifyPassword("anything", undefined), false);
});

test("password: hashes are salted and short passwords refused", async () => {
  assert.notEqual(await hashPassword("same-password-1"), await hashPassword("same-password-1"));
  await assert.rejects(() => hashPassword("short"));
  await burnPasswordCheck("whatever"); // must not throw
});

test("token: round trip, tamper, wrong secret, expiry, alg none", () => {
  const now = 1_800_000_000_000;
  const t = signToken({ sub: "u1", role: "reviewer" }, SECRET, { ttlSeconds: 60, now });
  assert.equal(verifyToken(t, SECRET, { now: now + 1000 }).sub, "u1");
  assert.equal(verifyToken(t, "y".repeat(40), { now }), null);
  assert.equal(verifyToken(t, SECRET, { now: now + 61_000 }), null);
  const [h, , s] = t.split(".");
  const forged = Buffer.from(JSON.stringify({ sub: "u1", role: "administrator", exp: 9999999999 })).toString("base64url");
  assert.equal(verifyToken(`${h}.${forged}.${s}`, SECRET, { now }), null);
  const none = Buffer.from(JSON.stringify({ alg: "none", typ: "JWT" })).toString("base64url");
  assert.equal(verifyToken(`${none}.${forged}.`, SECRET, { now }), null);
  assert.equal(verifyToken(undefined, SECRET), null);
  assert.equal(verifyToken("a.b", SECRET), null);
});

test("rate limiter blocks after max failures and recovers after the window", () => {
  let t = 0;
  const rl = createRateLimiter({ max: 3, windowMs: 1000, now: () => t });
  for (let i = 0; i < 3; i++) rl.fail("k");
  assert.equal(rl.isBlocked("k"), true);
  assert.equal(rl.isBlocked("other"), false);
  t = 1001;
  assert.equal(rl.isBlocked("k"), false);
  rl.fail("k");
  rl.reset("k");
  assert.equal(rl.isBlocked("k"), false);
});
