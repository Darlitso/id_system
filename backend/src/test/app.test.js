import test from "node:test";
import assert from "node:assert/strict";
import { createApp } from "../app.js";

async function withServer(app, fn) {
  const server = app.listen(0);
  try {
    await fn(`http://127.0.0.1:${server.address().port}`);
  } finally {
    server.close();
  }
}

test("health + request id", async () => {
  await withServer(createApp({}), async (base) => {
    const res = await fetch(`${base}/api/health`);
    assert.equal(res.status, 200);
    assert.match(res.headers.get("x-request-id"), /^[0-9a-f-]{36}$/);
  });
});

test("db health: ok, failing, and not configured", async () => {
  const ok = { query: async () => ({}) };
  const bad = { query: async () => { throw new Error("down"); } };
  await withServer(createApp({ pool: ok }), async (b) =>
    assert.equal((await fetch(`${b}/api/health/db`)).status, 200));
  await withServer(createApp({ pool: bad }), async (b) => {
    const res = await fetch(`${b}/api/health/db`);
    assert.equal(res.status, 503);
    assert.deepEqual(await res.json(), { status: "unavailable" }); // no error details leaked
  });
  await withServer(createApp({}), async (b) =>
    assert.equal((await fetch(`${b}/api/health/db`)).status, 503));
});

test("unknown route returns 404 json; bad request id is replaced", async () => {
  await withServer(createApp({}), async (base) => {
    const res = await fetch(`${base}/nope`, { headers: { "x-request-id": "not-a-uuid" } });
    assert.equal(res.status, 404);
    assert.notEqual(res.headers.get("x-request-id"), "not-a-uuid");
  });
});
