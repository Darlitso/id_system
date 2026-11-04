import "dotenv/config";
import { createApp } from "./app.js";
import { createPool } from "./config/db.js";

const PORT = process.env.PORT || 3000;

const pool = createPool();
const app = createApp({ pool });

const server = app.listen(PORT, () => {
  console.log(`API running on http://localhost:${PORT}`);
});

async function shutdown(signal) {
  console.log(`${signal} received, shutting down`);
  server.close(async () => {
    await pool.end();
    process.exit(0);
  });
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
