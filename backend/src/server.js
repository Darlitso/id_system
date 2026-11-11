// import "dotenv/config";
// import { createApp } from "./app.js";
// import { createPool } from "./config/db.js";

// const PORT = process.env.PORT || 3000;

// const pool = createPool();
// const app = createApp({ pool });

// const server = app.listen(PORT, () => {
//   console.log(`API running on http://localhost:${PORT}`);
// });

// async function shutdown(signal) {
//   console.log(`${signal} received, shutting down`);
//   server.close(async () => {
//     await pool.end();
//     process.exit(0);
//   });
// }

// process.on("SIGINT", () => shutdown("SIGINT"));
// process.on("SIGTERM", () => shutdown("SIGTERM"));


import "dotenv/config";

import { createApp } from "./app.js";
import { createPool } from "./config/db.js";
import { loadSettings } from "./config/settings.js";
import { loadKeyring, createTemplateCipher } from "./biometrics/cipher.js";
import { createAuth } from "./middleware/auth.js";

const env = process.env;
const PORT = env.PORT || 3000;

// Initialise and validate runtime configuration.
const settings = loadSettings(env);

// Initialise biometric encryption.
const keyring = loadKeyring(env);
const cipher = createTemplateCipher(keyring);

// Initialise authentication middleware.
const requireAuth = createAuth({
  secret: settings.sessionSecret,
});

// Initialise database connection.
const pool = createPool(env);

// Build application with all required dependencies.
const app = createApp({
  pool,
  env,
  settings,
  cipher,
  requireAuth,
});

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

