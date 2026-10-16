
import pg from "pg";
import "dotenv/config";

const { Pool } = pg;

export const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: {
    rejectUnauthorized: true,
  },
  max: 5,
  connectionTimeoutMillis: 10000,
});

pool.on("error", (error) => {
  console.error("Unexpected database pool error:", error.message);
});
