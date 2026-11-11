// import { randomUUID } from "node:crypto";
// import express from "express";
// import cors from "cors";
// import helmet from "helmet";

// const UUID_RE =
//   /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// export function createApp({ pool, env = process.env } = {}) {
//   const app = express();

//   const origins = (env.CORS_ORIGIN || "http://localhost:5173")
//     .split(",")
//     .map((o) => o.trim())
//     .filter(Boolean);

//   app.use(helmet());
//   app.use(cors({ origin: origins }));
//   app.use(express.json({ limit: "100kb" }));

//   // Request ID for correlation with audit.events.request_id (must be a UUID).
//   app.use((req, res, next) => {
//     const incoming = req.get("x-request-id");
//     req.id = incoming && UUID_RE.test(incoming) ? incoming : randomUUID();
//     res.set("x-request-id", req.id);
//     next();
//   });

//   app.get("/api/health", (req, res) => {
//     res.json({
//       status: "ok",
//       message: "Proposed identity system API is running",
//     });
//   });

//   app.get("/api/health/db", async (req, res) => {
//     if (!pool) {
//       return res.status(503).json({ status: "unavailable" });
//     }
//     try {
//       await pool.query("select 1");
//       return res.json({ status: "ok" });
//     } catch (error) {
//       console.error(`[${req.id}] db health check failed:`, error.message);
//       return res.status(503).json({ status: "unavailable" });
//     }
//   });

//   app.use((req, res) => {
//     res.status(404).json({ error: "not_found" });
//   });

//   // eslint-disable-next-line no-unused-vars
//   app.use((error, req, res, next) => {
//     console.error(`[${req.id}] unhandled error:`, error.message);
//     res.status(500).json({ error: "internal_error", requestId: req.id });
//   });

//   return app;
// }


import { randomUUID } from "node:crypto";
import express from "express";
import cors from "cors";
import helmet from "helmet";

import { toHttpError } from "./db/api.js";

import { authRoutes } from "./routes/auth.js";
import { enrolmentRoutes } from "./routes/enrolments.js";
import { reviewRoutes } from "./routes/review.js";
import { verifyRoutes } from "./routes/verify.js";

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function createApp({
  pool,
  env = process.env,
  settings,
  cipher,
  requireAuth,
} = {}) {
  const app = express();

  const origins = (env.CORS_ORIGIN || "http://localhost:5173")
    .split(",")
    .map((o) => o.trim())
    .filter(Boolean);

  app.use(helmet());
  app.use(cors({ origin: origins }));
  app.use(express.json({ limit: "100kb" }));

  // Request ID for correlation with audit.events.request_id.
  app.use((req, res, next) => {
    const incoming = req.get("x-request-id");
    req.id = incoming && UUID_RE.test(incoming) ? incoming : randomUUID();
    res.set("x-request-id", req.id);
    next();
  });

  // Health checks.
  app.get("/api/health", (req, res) => {
    res.json({
      status: "ok",
      message: "Proposed identity system API is running",
    });
  });

  app.get("/api/health/db", async (req, res) => {
    if (!pool) {
      return res.status(503).json({ status: "unavailable" });
    }

    try {
      await pool.query("select 1");
      return res.json({ status: "ok" });
    } catch (error) {
      console.error(`[${req.id}] db health check failed:`, error.message);
      return res.status(503).json({ status: "unavailable" });
    }
  });

  // Register application routes when runtime dependencies are supplied.
  if (pool && settings && cipher && requireAuth) {
    const routeDependencies = {
      pool,
      settings,
      cipher,
      requireAuth,
    };

    app.use("/api", authRoutes(routeDependencies));
    app.use("/api", enrolmentRoutes(routeDependencies));
    app.use("/api", reviewRoutes(routeDependencies));
    app.use("/api", verifyRoutes(routeDependencies));
  }

  // Unknown routes.
  app.use((req, res) => {
    res.status(404).json({ error: "not_found" });
  });

  // Central error handler.
  // eslint-disable-next-line no-unused-vars
  app.use((error, req, res, next) => {
    const mapped = toHttpError(error);

    if (mapped) {
      return res.status(mapped.status).json({
        error: mapped.code,
        message: mapped.message,
        requestId: req.id,
      });
    }

    console.error(`[${req.id}] unhandled error:`, error.message);

    return res.status(500).json({
      error: "internal_error",
      requestId: req.id,
    });
  });

  return app;
}
