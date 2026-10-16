import fs from "node:fs";
import pg from "pg";

const { Pool } = pg;

function sslConfig(env) {
  if (env.DATABASE_SSL === "disable") {
    return false; // local development only
  }
  const config = { rejectUnauthorized: true };
  if (env.DATABASE_SSL_CA_PATH) {
    config.ca = fs.readFileSync(env.DATABASE_SSL_CA_PATH, "utf8");
  }
  return config;
}

export function createPool(env = process.env) {
  if (!env.DATABASE_URL) {
    throw new Error("DATABASE_URL is not set");
  }

  const pool = new Pool({
    connectionString: env.DATABASE_URL,
    ssl: sslConfig(env),
    max: 5,
    connectionTimeoutMillis: 10000,
  });

  pool.on("error", (error) => {
    console.error("Unexpected database pool error:", error.message);
  });

  return pool;
}
