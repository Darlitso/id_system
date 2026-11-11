// Runtime settings read from the environment, validated once at start-up.
function num(env, name, fallback, { min = -Infinity, max = Infinity } = {}) {
  const raw = env[name];
  if (raw === undefined || raw === "") return fallback;
  const value = Number(raw);
  if (!Number.isFinite(value) || value < min || value > max) {
    throw new Error(`${name} must be a number between ${min} and ${max}`);
  }
  return value;
}

export function loadSettings(env = process.env) {
  const secret = env.SESSION_SECRET ?? "";
  if (secret.length < 32) {
    throw new Error("SESSION_SECRET must be set to a random string of at least 32 characters");
  }
  const production = env.NODE_ENV === "production";
  return {
    sessionSecret: secret,
    sessionTtlSeconds: num(env, "SESSION_TTL_MINUTES", 60, { min: 5, max: 1440 }) * 60,
    // The scanner simulator can never be switched on in production.
    simulator: env.ENABLE_BIOMETRIC_SIMULATOR === "true" && !production,
    // Duplicate search is built but off by default, until the connected flow is signed off.
    dedupEnabled: env.DEDUP_ENABLED === "true",
    reviewScore: num(env, "DEDUP_REVIEW_SCORE", 40, { min: 0, max: 100 }),
    verifyMinScore: num(env, "VERIFY_MIN_SCORE", 60, { min: 0, max: 100 }),
  };
}
