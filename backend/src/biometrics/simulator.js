import { randomBytes, randomInt } from "node:crypto";

// DEV ONLY scanner stand-in. There is no scanner hardware in the prototype, so the server
// fabricates templates when ENABLE_BIOMETRIC_SIMULATOR=true (never in production).
export const TEMPLATE_BYTES = 256; // 2048-bit code, the size the placeholder matchers expect

export const randomTemplate = () => randomBytes(TEMPLATE_BYTES);

// A second capture of the same finger/iris: the original with a few random bit errors.
export function noisyCopy(template, flipFraction = 0.06) {
  const out = Buffer.from(template);
  const bits = out.length * 8;
  const target = Math.round(bits * flipFraction);
  const chosen = new Set();
  while (chosen.size < target) chosen.add(randomInt(bits));
  for (const i of chosen) out[i >> 3] ^= 1 << (7 - (i & 7));
  return out;
}

export const randomQuality = () => Math.round((72 + Math.random() * 26) * 10) / 10;
