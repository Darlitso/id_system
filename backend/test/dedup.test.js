import test from "node:test";
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { irisScore } from "../src/dedup/irisMatcher.js";
import { findCandidates } from "../src/dedup/candidates.js";

// Synthetic data only.
const code = () => randomBytes(256); // 2048 bits
function noisy(buf, flipFraction) {
  const out = Buffer.from(buf);
  const bits = out.length * 8;
  for (let i = 0; i < Math.floor(bits * flipFraction); i++) {
    const p = Math.floor(Math.random() * bits);
    out[p >> 3] ^= 1 << (7 - (p & 7));
  }
  return out;
}
function rotate(buf, bitsLeft) {
  const n = buf.length * 8;
  const out = Buffer.alloc(buf.length);
  for (let i = 0; i < n; i++) {
    const bit = (buf[((i + bitsLeft) % n) >> 3] >> (7 - (((i + bitsLeft) % n) & 7))) & 1;
    if (bit) out[i >> 3] |= 1 << (7 - (i & 7));
  }
  return out;
}

test("identical code scores 100", () => {
  const a = code();
  assert.equal(irisScore(a, a), 100);
});

test("same eye with noise scores high; different eyes score low", () => {
  const a = code();
  const genuine = irisScore(a, noisy(a, 0.1));
  const impostor = irisScore(a, code());
  assert.ok(genuine > 60, `genuine=${genuine}`);
  assert.ok(impostor < 15, `impostor=${impostor}`);
});

test("small rotation is tolerated", () => {
  const a = code();
  assert.ok(irisScore(a, rotate(a, 5)) > 95);
});

test("mask excludes unusable bits", () => {
  const a = code();
  const b = Buffer.from(a);
  for (let i = 0; i < 128; i++) b[i] = ~b[i] & 0xff; // corrupt first half
  const mask = Buffer.alloc(256, 0xff);
  mask.fill(0x00, 0, 128);
  assert.ok(irisScore(a, b, { maskA: mask, maskB: mask }) > 95);
  assert.ok(irisScore(a, b) < 60);
});

test("findCandidates: skips self, filters by threshold, best first, one row per citizen", () => {
  const probeCode = code();
  const matcher = (p, g) => irisScore(p, g);
  const gallery = [
    { citizenId: "self", modality: "iris", template: probeCode },
    { citizenId: "dup", modality: "iris", template: noisy(probeCode, 0.05) },
    { citizenId: "dup", modality: "iris", template: noisy(probeCode, 0.2) },
    { citizenId: "other", modality: "iris", template: code() },
    { citizenId: "fp", modality: "fingerprint", template: probeCode },
  ];
  const result = findCandidates({
    probe: { citizenId: "self", modality: "iris", template: probeCode },
    gallery,
    matcher,
    reviewScore: 40,
  });
  assert.equal(result.length, 1);
  assert.equal(result[0].candidateCitizenId, "dup");
  assert.equal(result[0].modality, "iris");
  assert.ok(result[0].matchScore >= 40 && result[0].matchScore <= 100);
});
