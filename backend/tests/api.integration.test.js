// End-to-end test: real HTTP -> Express -> pg -> identity.api_* functions in a real Postgres.
// Skipped unless TEST_DATABASE_URL (identity_api role) and TEST_ADMIN_DATABASE_URL (owner role,
// used only to give seeded staff a known test password) are set. Local databases only:
// the test writes data (enrolments, templates, audit events).
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import test from "node:test";
import pg from "pg";
import { createApp } from "../src/app.js";
import { hashPassword } from "../src/auth/password.js";
import { createTemplateCipher } from "../src/biometrics/cipher.js";

const { TEST_DATABASE_URL: apiUrl, TEST_ADMIN_DATABASE_URL: adminUrl } = process.env;
const enabled = Boolean(apiUrl && adminUrl);
const local = enabled && [apiUrl, adminUrl].every((u) => /@(localhost|127\.0\.0\.1)[:/]/.test(u));

test("API integration", { skip: !enabled ? "set TEST_DATABASE_URL and TEST_ADMIN_DATABASE_URL" : !local ? "local databases only" : false }, async (t) => {
  const PASSWORD = "TestPassw0rd!";
  const pool = new pg.Pool({ connectionString: apiUrl });
  const admin = new pg.Pool({ connectionString: adminUrl });
  const cipher = createTemplateCipher({ activeId: "t1", keys: new Map([["t1", randomBytes(32)]]) });
  const base = { sessionSecret: "s".repeat(40), sessionTtlSeconds: 600, simulator: true, reviewScore: 40, verifyMinScore: 60 };

  const hash = await hashPassword(PASSWORD);
  await admin.query("UPDATE identity.staff_users SET password_hash = $1 WHERE username = ANY($2)",
    [hash, ["officer.lusaka", "officer.kitwe", "reviewer.one", "provider.bank", "auditor.one", "admin.one"]]);

  const start = async (settings, limiterOptions) => {
    const server = createApp({ pool, cipher, settings: { ...base, ...settings }, env: { NODE_ENV: "test" }, limiterOptions }).listen(0);
    await new Promise((r) => server.once("listening", r));
    return { server, url: `http://127.0.0.1:${server.address().port}` };
  };
  const appPlain = await start({ dedupEnabled: false });
  const appDedup = await start({ dedupEnabled: true });
  const appLimited = await start({ dedupEnabled: false }, { max: 3 });
  t.after(async () => {
    for (const a of [appPlain, appDedup, appLimited]) await new Promise((r) => a.server.close(r));
    await pool.end();
    await admin.end();
  });

  const call = async (app, method, path, { token, body } = {}) => {
    const res = await fetch(app.url + path, {
      method,
      headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    const text = await res.text();
    assert.ok(!text.includes("scrypt$") && !text.includes("password_hash"), "responses must never contain password hashes");
    return { status: res.status, json: text ? JSON.parse(text) : null };
  };
  const login = async (app, username) => {
    const r = await call(app, "POST", "/api/auth/login", { body: { username, password: PASSWORD } });
    assert.equal(r.status, 200, `login ${username}`);
    return r.json.token;
  };

  await t.test("authentication", async () => {
    assert.equal((await call(appPlain, "GET", "/api/enrolments")).status, 401);
    assert.equal((await call(appPlain, "GET", "/api/enrolments", { token: "garbage" })).status, 401);
    const bad = await call(appPlain, "POST", "/api/auth/login", { body: { username: "officer.lusaka", password: "wrong-password" } });
    const ghost = await call(appPlain, "POST", "/api/auth/login", { body: { username: "nobody.here", password: "wrong-password" } });
    assert.equal(bad.status, 401);
    assert.deepEqual(bad.json.message, ghost.json.message, "same message whether or not the user exists");
    assert.equal((await call(appPlain, "POST", "/api/auth/login", { body: {} })).status, 400);
    const token = await login(appPlain, "officer.lusaka");
    const me = await call(appPlain, "GET", "/api/auth/me", { token });
    assert.equal(me.json.user.role, "registration_officer");
  });

  await t.test("login is rate limited", async () => {
    for (let i = 0; i < 3; i++) {
      assert.equal((await call(appLimited, "POST", "/api/auth/login", { body: { username: "rate.test", password: "nope-nope-nope" } })).status, 401);
    }
    assert.equal((await call(appLimited, "POST", "/api/auth/login", { body: { username: "rate.test", password: "nope-nope-nope" } })).status, 429);
  });

  const suffix = randomBytes(3).toString("hex");
  const nameA = `Integration Alpha ${suffix}`;
  const nameB = `Integration Bravo ${suffix}`;
  let officer, reviewer, provider, auditor, kitwe;
  let citizenA, enrolA, numberA;

  await t.test("enrolment is stored: enrol, capture (encrypted), approve, identity number issued", async () => {
    officer = await login(appPlain, "officer.lusaka");
    kitwe = await login(appPlain, "officer.kitwe");
    reviewer = await login(appPlain, "reviewer.one");
    provider = await login(appPlain, "provider.bank");
    auditor = await login(appPlain, "auditor.one");

    const centres = await call(appPlain, "GET", "/api/centres", { token: officer });
    assert.ok(centres.json.length >= 3);
    const lusaka = centres.json.find((c) => c.centre_code === "LSK-001");

    assert.equal((await call(appPlain, "POST", "/api/enrolments", { token: officer, body: { dateOfBirth: "1990-01-01" } })).status, 400);
    assert.equal((await call(appPlain, "POST", "/api/enrolments", { token: officer, body: { fullName: nameA, dateOfBirth: "2999-01-01" } })).status, 400);
    assert.equal((await call(appPlain, "POST", "/api/enrolments", { token: kitwe, body: { fullName: nameA, dateOfBirth: "1990-01-01", centreId: lusaka.centre_id } })).status, 403, "officers may only enrol at their own centre");

    const created = await call(appPlain, "POST", "/api/enrolments", { token: officer, body: { fullName: nameA, dateOfBirth: "1990-05-06", gender: "female", district: "Lusaka" } });
    assert.equal(created.status, 201);
    ({ citizenId: citizenA, enrolmentId: enrolA } = created.json);

    const noTemplate = await call(appPlain, "POST", `/api/enrolments/${enrolA}/biometrics`, { token: officer, body: { modality: "iris" } });
    assert.equal(noTemplate.status, 400);
    const wrongSize = await call(appPlain, "POST", `/api/enrolments/${enrolA}/biometrics`, { token: officer, body: { modality: "iris", template: Buffer.alloc(10).toString("base64") } });
    assert.equal(wrongSize.status, 400);
    assert.equal((await call(appPlain, "POST", `/api/enrolments/${enrolA}/biometrics`, { token: kitwe, body: { modality: "iris", simulate: {} } })).status, 404, "other centre cannot see this enrolment");

    for (const modality of ["fingerprint", "iris"]) {
      const r = await call(appPlain, "POST", `/api/enrolments/${enrolA}/biometrics`, { token: officer, body: { modality, simulate: {} } });
      assert.equal(r.status, 201);
      assert.equal(r.json.duplicateSearch.ran, false, "duplicate search is off in this app");
    }

    // The stored rows are ciphertext (IV + tag + payload), never the raw template.
    const { rows } = await admin.query("SELECT modality, status, encryption_key_id, octet_length(template_ciphertext) AS len FROM identity.biometric_templates WHERE citizen_id = $1", [citizenA]);
    assert.equal(rows.length, 2);
    for (const row of rows) {
      assert.equal(row.status, "active");
      assert.equal(row.encryption_key_id, "t1");
      assert.ok(row.len > 256, `ciphertext is larger than the 256-byte template, got ${row.len}`);
    }

    const denied = await call(appPlain, "POST", `/api/enrolments/${enrolA}/decision`, { token: officer, body: { decision: "approve" } });
    assert.equal(denied.status, 403, "an officer cannot approve (enforced by the database)");

    const approved = await call(appPlain, "POST", `/api/enrolments/${enrolA}/decision`, { token: reviewer, body: { decision: "approve" } });
    assert.equal(approved.status, 200);
    numberA = approved.json.identityNumber;
    assert.match(numberA, /^\d{6}\/\d{2}\/\d$/);
    assert.equal((await call(appPlain, "POST", `/api/enrolments/${enrolA}/decision`, { token: reviewer, body: { decision: "approve" } })).status, 409);

    const list = await call(appPlain, "GET", `/api/citizens?search=${encodeURIComponent(nameA)}`, { token: reviewer });
    assert.equal(list.json.length, 1);
    assert.equal(list.json[0].status, "active");
    assert.equal(list.json[0].identity_number, numberA);
    assert.ok(list.json[0].fingerprint_quality !== null && list.json[0].iris_quality !== null);
  });

  await t.test("duplicate search flags a repeat enrolment for human review", async () => {
    const created = await call(appDedup, "POST", "/api/enrolments", { token: officer, body: { fullName: nameB, dateOfBirth: "1991-02-03", district: "Lusaka" } });
    const enrolB = created.json.enrolmentId;
    const first = await call(appDedup, "POST", `/api/enrolments/${enrolB}/biometrics`, { token: officer, body: { modality: "fingerprint", simulate: { sameAs: citizenA } } });
    assert.equal(first.status, 201);
    assert.equal(first.json.duplicateSearch.ran, true);
    assert.equal(first.json.duplicateSearch.flagged, true);
    assert.ok(!JSON.stringify(first.json).includes(nameA), "officers are not told who the candidate is");
    await call(appDedup, "POST", `/api/enrolments/${enrolB}/biometrics`, { token: officer, body: { modality: "iris", simulate: {} } });

    const flagged = await call(appDedup, "GET", "/api/enrolments?status=flagged", { token: reviewer });
    assert.ok(flagged.json.some((e) => e.enrolment_id === enrolB && Number(e.open_matches) === 1));
    assert.equal((await call(appDedup, "POST", `/api/enrolments/${enrolB}/decision`, { token: reviewer, body: { decision: "approve" } })).status, 409);
    assert.equal((await call(appDedup, "GET", "/api/matches", { token: officer })).status, 403);

    const matches = await call(appDedup, "GET", "/api/matches?status=pending_review", { token: reviewer });
    const m = matches.json.find((x) => x.applicant_name === nameB);
    assert.ok(m, "match case visible to the reviewer");
    assert.equal(m.candidate_name, nameA);
    assert.ok(Number(m.match_score) > 75);

    assert.equal((await call(appDedup, "POST", `/api/matches/${m.match_case_id}/review`, { token: reviewer, body: { decision: "confirmed_duplicate", notes: "same fingerprint" } })).status, 200);
    const rejected = await call(appDedup, "GET", "/api/enrolments?status=rejected", { token: reviewer });
    assert.ok(rejected.json.some((e) => e.enrolment_id === enrolB));
    const none = await call(appDedup, "GET", `/api/citizens?search=${encodeURIComponent(nameB)}`, { token: reviewer });
    assert.equal(none.json[0].identity_number, null, "a duplicate never receives an identity number");
  });

  await t.test("service provider verification", async () => {
    const genuine = await call(appPlain, "POST", "/api/verify", { token: provider, body: { identityNumber: numberA, simulate: "genuine" } });
    assert.equal(genuine.json.result, "verified");
    assert.equal(genuine.json.name, nameA);
    const impostor = await call(appPlain, "POST", "/api/verify", { token: provider, body: { identityNumber: numberA, simulate: "impostor" } });
    assert.equal(impostor.json.result, "not_verified");
    assert.equal(impostor.json.name, undefined, "no name is released on a failed check");
    assert.equal((await call(appPlain, "POST", "/api/verify", { token: provider, body: { identityNumber: "999999/10/1", simulate: "genuine" } })).json.result, "not_verified");
    assert.equal((await call(appPlain, "POST", "/api/verify", { token: provider, body: { identityNumber: "100005/10/1", simulate: "genuine" } })).json.result, "revoked");
    assert.equal((await call(appPlain, "POST", "/api/verify", { token: provider, body: { identityNumber: "nonsense" } })).status, 400);
    assert.equal((await call(appPlain, "POST", "/api/verify", { token: officer, body: { identityNumber: numberA, simulate: "genuine" } })).status, 403);
  });

  await t.test("audit trail", async () => {
    assert.equal((await call(appPlain, "GET", "/api/audit", { token: officer })).status, 403);
    const all = await call(appPlain, "GET", "/api/audit?limit=500", { token: auditor });
    const actions = new Set(all.json.map((e) => e.action));
    for (const a of ["auth.login", "auth.login_failed", "enrolment.submit", "biometrics.store", "biometrics.gallery_read", "match.record", "match.review", "enrolment.approve", "verify.lookup", "verify.result"]) {
      assert.ok(actions.has(a), `audit contains ${a}`);
    }
    const denied = await call(appPlain, "GET", "/api/audit?outcome=denied&limit=500", { token: auditor });
    assert.ok(denied.json.some((e) => e.action.includes("/enrolments/:id/decision")), "the refused approval was recorded");
    const stats = await call(appPlain, "GET", "/api/stats", { token: reviewer });
    assert.equal(stats.json.enrolments_by_day.length, 7);
    assert.ok(stats.json.citizens_total >= 9);
  });
});
