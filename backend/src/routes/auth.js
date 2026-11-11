import { Router } from "express";
import { burnPasswordCheck, verifyPassword } from "../auth/password.js";
import { createRateLimiter } from "../auth/rateLimit.js";
import { signToken } from "../auth/token.js";
import { callApi, HttpError } from "../db/api.js";
import { ctx } from "./helpers.js";

export function authRoutes({ pool, settings, requireAuth, limiterOptions = {} }) {
  const router = Router();
  const perUser = createRateLimiter({ max: 5, ...limiterOptions });
  const perIp = createRateLimiter({ max: 30, ...limiterOptions });

  router.post("/auth/login", async (req, res) => {
    const { username, password } = req.body ?? {};
    if (typeof username !== "string" || typeof password !== "string" || !username || username.length > 80 || password.length > 200) {
      throw new HttpError(400, "invalid_request", "username and password are required");
    }
    const { requestId, ip } = ctx(req);
    const userKey = `${ip}|${username.toLowerCase()}`;
    if (perIp.isBlocked(String(ip)) || perUser.isBlocked(userKey)) {
      throw new HttpError(429, "too_many_attempts", "Too many failed attempts. Try again later.");
    }

    const [user] = await callApi(pool, "api_get_staff_login", [username]);
    let ok = false;
    if (user) ok = await verifyPassword(password, user.password_hash);
    else await burnPasswordCheck(password);

    if (!user || !ok || !user.is_active) {
      perUser.fail(userKey);
      perIp.fail(String(ip));
      await callApi(pool, "api_record_login", [user?.user_id ?? null, username, false, requestId, ip]);
      throw new HttpError(401, "invalid_credentials", "Incorrect username or password");
    }

    perUser.reset(userKey);
    await callApi(pool, "api_record_login", [user.user_id, username, true, requestId, ip]);
    const profile = {
      id: user.user_id,
      username: user.username,
      name: user.display_name,
      role: user.role,
      centreId: user.centre_id,
    };
    const token = signToken(
      { sub: profile.id, role: profile.role, name: profile.name, centre: profile.centreId },
      settings.sessionSecret,
      { ttlSeconds: settings.sessionTtlSeconds },
    );
    res.json({ token, expiresInSeconds: settings.sessionTtlSeconds, user: profile });
  });

  router.get("/auth/me", requireAuth(), (req, res) => {
    res.json({ user: req.user });
  });

  return router;
}
