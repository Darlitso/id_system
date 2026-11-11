import { randomBytes, scrypt, timingSafeEqual } from "node:crypto";
import { promisify } from "node:util";

const scryptAsync = promisify(scrypt);
const N = 16384;
const R = 8;
const P = 1;
const KEYLEN = 64;

// Format: scrypt$N$r$p$salt(base64)$hash(base64). Built-in crypto only, no native add-ons.
export async function hashPassword(password) {
  if (typeof password !== "string" || password.length < 10) {
    throw new Error("Password must be at least 10 characters");
  }
  const salt = randomBytes(16);
  const key = await scryptAsync(password, salt, KEYLEN, { N, r: R, p: P });
  return `scrypt$${N}$${R}$${P}$${salt.toString("base64")}$${key.toString("base64")}`;
}

export async function verifyPassword(password, stored) {
  try {
    if (typeof password !== "string" || typeof stored !== "string") return false;
    const [scheme, n, r, p, saltB64, hashB64] = stored.split("$");
    if (scheme !== "scrypt" || !hashB64) return false;
    const expected = Buffer.from(hashB64, "base64");
    const salt = Buffer.from(saltB64, "base64");
    const actual = await scryptAsync(password, salt, expected.length, {
      N: Number(n),
      r: Number(r),
      p: Number(p),
    });
    return actual.length === expected.length && timingSafeEqual(actual, expected);
  } catch {
    return false;
  }
}

// Used when the username does not exist, so response time does not reveal valid usernames.
let dummy;
export async function burnPasswordCheck(password) {
  dummy ??= await hashPassword("dummy-password-for-timing");
  await verifyPassword(password, dummy);
}
