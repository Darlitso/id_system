import { createHmac, timingSafeEqual } from "node:crypto";

// Standard HS256 JWT layout, built on node:crypto so no extra dependency is needed.
const b64u = (value) => Buffer.from(value).toString("base64url");
const HEADER = b64u(JSON.stringify({ alg: "HS256", typ: "JWT" }));

function sign(data, secret) {
  return createHmac("sha256", secret).update(data).digest("base64url");
}

export function signToken(payload, secret, { ttlSeconds, now = Date.now() }) {
  const iat = Math.floor(now / 1000);
  const body = b64u(JSON.stringify({ ...payload, iat, exp: iat + ttlSeconds }));
  const data = `${HEADER}.${body}`;
  return `${data}.${sign(data, secret)}`;
}

export function verifyToken(token, secret, { now = Date.now() } = {}) {
  if (typeof token !== "string") return null;
  const parts = token.split(".");
  if (parts.length !== 3 || parts[0] !== HEADER) return null; // rejects alg=none and other algorithms
  const expected = Buffer.from(sign(`${parts[0]}.${parts[1]}`, secret));
  const given = Buffer.from(parts[2]);
  if (expected.length !== given.length || !timingSafeEqual(expected, given)) return null;
  try {
    const payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
    if (typeof payload.exp !== "number" || payload.exp * 1000 <= now) return null;
    return payload;
  } catch {
    return null;
  }
}
