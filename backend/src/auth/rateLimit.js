// Small in-memory limiter for login attempts. One instance per process: fine for a
// single server; use a shared store (e.g. Redis) if the API is ever scaled out.
export function createRateLimiter({ max = 5, windowMs = 15 * 60 * 1000, now = () => Date.now() } = {}) {
  const entries = new Map();
  return {
    isBlocked(key) {
      const e = entries.get(key);
      return Boolean(e && e.resetAt > now() && e.count >= max);
    },
    fail(key) {
      const t = now();
      const e = entries.get(key);
      if (!e || e.resetAt <= t) {
        if (entries.size > 10000) {
          for (const [k, v] of entries) if (v.resetAt <= t) entries.delete(k);
        }
        entries.set(key, { count: 1, resetAt: t + windowMs });
      } else {
        e.count += 1;
      }
    },
    reset(key) {
      entries.delete(key);
    },
  };
}
