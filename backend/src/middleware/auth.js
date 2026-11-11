import { verifyToken } from "../auth/token.js";
import { HttpError } from "../db/api.js";

// Verifies the bearer token. Roles listed here are a fast first check only: the database
// re-checks the staff member's role and active flag on every call and is the real authority.
export function createAuth({ secret }) {
  return function requireAuth(roles) {
    return (req, res, next) => {
      const header = req.get("authorization") ?? "";
      const token = header.startsWith("Bearer ") ? header.slice(7) : null;
      const payload = verifyToken(token, secret);
      if (!payload) return next(new HttpError(401, "unauthenticated", "Please sign in"));
      if (roles && !roles.includes(payload.role)) {
        return next(new HttpError(403, "forbidden", "You are not permitted to do this"));
      }
      req.user = { id: payload.sub, role: payload.role, name: payload.name, centreId: payload.centre ?? null };
      next();
    };
  };
}
