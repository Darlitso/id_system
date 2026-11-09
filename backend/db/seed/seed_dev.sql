-- =====================================================================
-- seed_dev.sql  --  DEVELOPMENT DATA ONLY
-- All names, numbers, hashes and keys below are FAKE.
-- Never run this against a database holding real citizen data.
-- Safe to re-run: inserts use ON CONFLICT DO NOTHING; audit events load only into an empty audit table.
-- Requires the identity and audit schemas to exist first.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- Registration centres
-- ---------------------------------------------------------------------
INSERT INTO identity.registration_centres (centre_id, centre_code, name, district) VALUES
 ('a1000000-0000-0000-0000-000000000001', 'LSK-001', 'Lusaka Central Registration Centre', 'Lusaka'),
 ('a1000000-0000-0000-0000-000000000002', 'KTW-001', 'Kitwe Registration Centre',          'Kitwe'),
 ('a1000000-0000-0000-0000-000000000003', 'LVG-001', 'Livingstone Registration Centre',    'Livingstone')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- Staff (password_hash values are placeholders, NOT usable logins;
-- your backend will create real hashes later)
-- ---------------------------------------------------------------------
INSERT INTO identity.staff_users
 (user_id, username, password_hash, display_name, role, centre_id, mfa_enabled) VALUES
 ('b1000000-0000-0000-0000-000000000001', 'officer.lusaka',  'FAKE_HASH_DEV_ONLY', 'Officer Lusaka',     'registration_officer', 'a1000000-0000-0000-0000-000000000001', false),
 ('b1000000-0000-0000-0000-000000000002', 'officer.kitwe',   'FAKE_HASH_DEV_ONLY', 'Officer Kitwe',      'registration_officer', 'a1000000-0000-0000-0000-000000000002', false),
 ('b1000000-0000-0000-0000-000000000003', 'officer.livingstone','FAKE_HASH_DEV_ONLY','Officer Livingstone','registration_officer','a1000000-0000-0000-0000-000000000003', false),
 ('b1000000-0000-0000-0000-000000000004', 'reviewer.one',   'FAKE_HASH_DEV_ONLY', 'Reviewer One',       'reviewer',             NULL, true),
 ('b1000000-0000-0000-0000-000000000005', 'admin.one',       'FAKE_HASH_DEV_ONLY', 'Administrator One',  'administrator',        NULL, true),
 ('b1000000-0000-0000-0000-000000000006', 'provider.bank',   'FAKE_HASH_DEV_ONLY', 'Demo Bank (service provider)', 'service_provider', NULL, false),
 ('b1000000-0000-0000-0000-000000000007', 'auditor.one',     'FAKE_HASH_DEV_ONLY', 'Auditor One',        'auditor',              NULL, true)
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- Citizens (identity numbers are fake)
-- ---------------------------------------------------------------------
INSERT INTO identity.citizens
 (citizen_id, identity_number, full_name, date_of_birth, place_of_birth, gender_code,
  village, district, chief, registration_date, address_text, status) VALUES
 ('c1000000-0000-0000-0000-000000000001', '100001/10/1', 'Mwansa Chileshe', '1990-03-14', 'Lusaka',      'male',   'Chilenje',  'Lusaka',      NULL, '2026-09-01', 'Plot 12, Chilenje, Lusaka',      'active'),
 ('c1000000-0000-0000-0000-000000000002', '100002/10/1', 'Natasha Banda',   '1995-07-22', 'Kitwe',       'female', 'Chimwemwe', 'Kitwe',       NULL, '2026-09-03', 'House 8, Chimwemwe, Kitwe',      'active'),
 ('c1000000-0000-0000-0000-000000000003', '100003/10/1', 'Joseph Phiri',    '1982-11-05', 'Livingstone', 'male',   'Dambwa',    'Livingstone', NULL, '2026-09-05', 'Dambwa North, Livingstone',      'active'),
 ('c1000000-0000-0000-0000-000000000004', NULL,          'Grace Mulenga',   '2000-01-30', 'Lusaka',      'female', 'Matero',    'Lusaka',      NULL, '2026-10-20', 'Matero, Lusaka',                 'pending'),
 ('c1000000-0000-0000-0000-000000000005', '100005/10/1', 'Peter Zulu',      '1975-06-18', 'Kitwe',       'male',   'Kwacha',    'Kitwe',       NULL, '2026-09-07', 'Kwacha East, Kitwe',             'suspended'),
 ('c1000000-0000-0000-0000-000000000006', NULL,          'Natasha Banda',   '1995-07-22', 'Kitwe',       'female', 'Chimwemwe', 'Kitwe',       NULL, '2026-10-25', 'Lusaka (duplicate attempt)',     'pending'),
 ('c1000000-0000-0000-0000-000000000007', NULL,          'Brian Tembo',     '1998-09-09', 'Livingstone', 'male',   'Maramba',   'Livingstone', NULL, '2026-10-22', 'Maramba, Livingstone',           'pending')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- Enrolments (one per citizen, in different workflow states)
-- ---------------------------------------------------------------------
INSERT INTO identity.enrolments
 (enrolment_id, citizen_id, centre_id, captured_by, status, submitted_at, decided_at, decided_by, decision_reason) VALUES
 ('e1000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', 'approved',  '2026-09-01 10:00+02', '2026-09-02 09:00+02', 'b1000000-0000-0000-0000-000000000004', 'Documents verified'),
 ('e1000000-0000-0000-0000-000000000002', 'c1000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000002', 'approved',  '2026-09-03 11:00+02', '2026-09-04 09:30+02', 'b1000000-0000-0000-0000-000000000004', 'Documents verified'),
 ('e1000000-0000-0000-0000-000000000003', 'c1000000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000003', 'b1000000-0000-0000-0000-000000000003', 'approved',  '2026-09-05 12:00+02', '2026-09-06 08:45+02', 'b1000000-0000-0000-0000-000000000004', 'Documents verified'),
 ('e1000000-0000-0000-0000-000000000004', 'c1000000-0000-0000-0000-000000000004', 'a1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', 'submitted', '2026-10-20 14:00+02', NULL, NULL, NULL),
 ('e1000000-0000-0000-0000-000000000005', 'c1000000-0000-0000-0000-000000000006', 'a1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', 'flagged',   '2026-10-25 15:00+02', NULL, NULL, NULL),
 ('e1000000-0000-0000-0000-000000000006', 'c1000000-0000-0000-0000-000000000007', 'a1000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000002', 'rejected',  '2026-10-22 10:30+02', '2026-10-23 09:00+02', 'b1000000-0000-0000-0000-000000000004', 'Supporting documents incomplete'),
 ('e1000000-0000-0000-0000-000000000007', 'c1000000-0000-0000-0000-000000000005', 'a1000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000002', 'approved',  '2026-09-07 10:00+02', '2026-09-08 09:00+02', 'b1000000-0000-0000-0000-000000000004', 'Documents verified')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- Biometric templates are NOT seeded. Real rows must be encrypted by the backend
-- (src/biometrics/cipher.js, AES-256-GCM bound to citizen + modality), so fake bytes
-- here would only fail to decrypt. Create test templates through the API instead.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- Credentials (token hashes are SHA-256 of dummy strings)
-- ---------------------------------------------------------------------
INSERT INTO identity.credentials
 (credential_id, citizen_id, token_id, token_hash, signature_algorithm, signing_key_id, issued_at, expires_at, status, revoked_at, revoked_by, revocation_reason) VALUES
 ('d1000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'd2000000-0000-0000-0000-000000000001', sha256(convert_to('dev-token-1','UTF8')), 'Ed25519', 'dev-signing-key-1', '2026-09-02 10:00+02', '2036-09-02 10:00+02', 'active',  NULL, NULL, NULL),
 ('d1000000-0000-0000-0000-000000000002', 'c1000000-0000-0000-0000-000000000002', 'd2000000-0000-0000-0000-000000000002', sha256(convert_to('dev-token-2','UTF8')), 'Ed25519', 'dev-signing-key-1', '2026-09-04 10:00+02', '2036-09-04 10:00+02', 'active',  NULL, NULL, NULL),
 ('d1000000-0000-0000-0000-000000000003', 'c1000000-0000-0000-0000-000000000003', 'd2000000-0000-0000-0000-000000000003', sha256(convert_to('dev-token-3','UTF8')), 'Ed25519', 'dev-signing-key-1', '2026-09-06 10:00+02', '2036-09-06 10:00+02', 'active',  NULL, NULL, NULL),
 ('d1000000-0000-0000-0000-000000000004', 'c1000000-0000-0000-0000-000000000005', 'd2000000-0000-0000-0000-000000000004', sha256(convert_to('dev-token-4','UTF8')), 'Ed25519', 'dev-signing-key-1', '2026-09-08 10:00+02', '2036-09-08 10:00+02', 'revoked', '2026-10-10 09:00+02', 'b1000000-0000-0000-0000-000000000005', 'Citizen suspended pending investigation')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- Match cases (duplicate detection for the flagged enrolment)
-- ---------------------------------------------------------------------
INSERT INTO identity.match_cases
 (match_case_id, enrolment_id, candidate_citizen_id, modality, match_score, status, reviewed_by, reviewed_at, review_notes) VALUES
 ('a2000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000005', 'c1000000-0000-0000-0000-000000000002', 'fingerprint', 96.4210, 'pending_review', NULL, NULL, NULL),
 ('a2000000-0000-0000-0000-000000000002', 'e1000000-0000-0000-0000-000000000005', 'c1000000-0000-0000-0000-000000000003', 'iris',        38.0100, 'false_match',    'b1000000-0000-0000-0000-000000000004', '2026-10-26 09:00+02', 'Score too low, different person')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- Verification events (a service provider checking credentials)
-- ---------------------------------------------------------------------
INSERT INTO identity.verification_events
 (verification_id, credential_id, provider_user_id, token_id, result, reason_code, occurred_at) VALUES
 ('a3000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000006', 'd2000000-0000-0000-0000-000000000001', 'verified',     NULL,        '2026-10-27 09:15+02'),
 ('a3000000-0000-0000-0000-000000000002', 'd1000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000006', 'd2000000-0000-0000-0000-000000000002', 'verified',     NULL,        '2026-10-27 09:40+02'),
 ('a3000000-0000-0000-0000-000000000003', 'd1000000-0000-0000-0000-000000000004', 'b1000000-0000-0000-0000-000000000006', 'd2000000-0000-0000-0000-000000000004', 'revoked',      'CITIZEN_SUSPENDED', '2026-10-28 14:05+02'),
 ('a3000000-0000-0000-0000-000000000004', NULL,                                   'b1000000-0000-0000-0000-000000000006', NULL,                                   'not_verified', 'UNKNOWN_TOKEN',     '2026-10-28 16:20+02')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- Audit events (audit_id is generated automatically)
-- ---------------------------------------------------------------------
DO $seed$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM audit.events) THEN
INSERT INTO audit.events
 (occurred_at, actor_user_id, actor_role, action, entity_type, entity_id, outcome, source_ip, details) VALUES
 ('2026-09-01 10:00+02', 'b1000000-0000-0000-0000-000000000001', 'registration_officer', 'enrolment.submit',   'enrolment',  'e1000000-0000-0000-0000-000000000001', 'success', '10.0.0.11', '{"centre":"LSK-001"}'),
 ('2026-09-02 09:00+02', 'b1000000-0000-0000-0000-000000000004', 'reviewer',             'enrolment.approve',  'enrolment',  'e1000000-0000-0000-0000-000000000001', 'success', '10.0.0.21', '{}'),
 ('2026-10-10 09:00+02', 'b1000000-0000-0000-0000-000000000005', 'administrator',        'credential.revoke',  'credential', 'd1000000-0000-0000-0000-000000000004', 'success', '10.0.0.31', '{"reason":"suspension"}'),
 ('2026-10-26 08:50+02', 'b1000000-0000-0000-0000-000000000001', 'registration_officer', 'citizen.update',     'citizen',    'c1000000-0000-0000-0000-000000000002', 'denied',  '10.0.0.11', '{"why":"officer cannot edit active citizens"}'),
 ('2026-10-28 16:20+02', 'b1000000-0000-0000-0000-000000000006', 'service_provider',     'credential.verify',  'credential', NULL,                                   'failure', '10.0.0.41', '{"reason":"unknown token"}');
  END IF;
END
$seed$;

COMMIT;

-- ---------------------------------------------------------------------
-- To wipe the dummy data later (development databases only):
--   TRUNCATE audit.events, identity.verification_events, identity.match_cases,
--            identity.credentials, identity.biometric_templates,
--            identity.enrolments, identity.citizens,
--            identity.staff_users, identity.registration_centres
--   RESTART IDENTITY CASCADE;
-- ---------------------------------------------------------------------
