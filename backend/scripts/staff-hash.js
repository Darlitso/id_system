// Creates a password hash locally and prints the SQL to store it. Nothing here connects to
// a database and no password is ever written to disk or committed.
//   node scripts/staff-hash.js officer.lusaka     -> UPDATE for one user
//   node scripts/staff-hash.js --dev-all          -> UPDATE for every seeded user still on the placeholder hash
import { hashPassword } from "../src/auth/password.js";

function askHidden(prompt) {
  return new Promise((resolve) => {
    process.stdout.write(prompt);
    const stdin = process.stdin;
    let value = "";
    stdin.setRawMode?.(true);
    stdin.resume();
    stdin.setEncoding("utf8");
    const onData = (ch) => {
      for (const c of ch) {
        if (c === "\r" || c === "\n") {
          stdin.setRawMode?.(false);
          stdin.pause();
          stdin.off("data", onData);
          process.stdout.write("\n");
          return resolve(value);
        }
        if (c === "\u0003") process.exit(1);
        if (c === "\u007f" || c === "\b") value = value.slice(0, -1);
        else value += c;
      }
    };
    stdin.on("data", onData);
  });
}

const target = process.argv[2];
if (!target) {
  console.error("Usage: node scripts/staff-hash.js <username> | --dev-all");
  process.exit(1);
}
const first = await askHidden("New password (min 10 characters): ");
const second = await askHidden("Repeat password: ");
if (first !== second) {
  console.error("Passwords do not match.");
  process.exit(1);
}
const hash = await hashPassword(first);
const where =
  target === "--dev-all"
    ? "WHERE password_hash = 'FAKE_HASH_DEV_ONLY'"
    : `WHERE username = '${target.replace(/'/g, "''")}'`;
console.log("\nRun this in the Supabase SQL Editor (or psql):\n");
console.log(`UPDATE identity.staff_users SET password_hash = '${hash}' ${where};`);
