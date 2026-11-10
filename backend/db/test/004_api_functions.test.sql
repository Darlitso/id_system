-- 004_api_functions.test.sql
-- Behaviour tests for the identity.api_* functions, run AS the identity_api role.
-- Run ONLY on a throwaway/local test database after 000-004 and the dev seed.
-- Everything happens inside a transaction that is rolled back at the end.
--   psql -d identity_test -v ON_ERROR_STOP=1 -f backend/db/tests/004_api_functions.test.sql
BEGIN;

CREATE SCHEMA t;
GRANT USAGE ON SCHEMA t TO identity_api;
-- Runs a statement and asserts it fails with the given SQLSTATE.
CREATE FUNCTION t.expect(p_sql text, p_state text) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  EXECUTE p_sql;
  RAISE EXCEPTION 'EXPECTED ERROR % BUT STATEMENT SUCCEEDED: %', p_state, p_sql;
EXCEPTION WHEN OTHERS THEN
  IF SQLSTATE <> p_state THEN
    RAISE EXCEPTION 'EXPECTED % BUT GOT % (%): %', p_state, SQLSTATE, SQLERRM, p_sql;
  END IF;
END $f$;
GRANT EXECUTE ON FUNCTION t.expect(text, text) TO identity_api;

DO $test$
DECLARE
  officer1 uuid := 'b1000000-0000-0000-0000-000000000001';  -- Lusaka officer
  officer2 uuid := 'b1000000-0000-0000-0000-000000000002';  -- Kitwe officer
  reviewer uuid := 'b1000000-0000-0000-0000-000000000004';
  provider uuid := 'b1000000-0000-0000-0000-000000000006';
  centre1  uuid := 'a1000000-0000-0000-0000-000000000001';
  centre2  uuid := 'a1000000-0000-0000-0000-000000000002';
  c1 uuid; e1 uuid; c2 uuid; e2 uuid; c3 uuid; e3 uuid;
  m1 uuid; m2 uuid; num text; n int; blob bytea := decode(repeat('ab', 40), 'hex');
BEGIN
  SET LOCAL ROLE identity_api;

  -- Direct table access is denied
  PERFORM t.expect('SELECT 1 FROM identity.citizens', '42501');
  PERFORM t.expect('SELECT 1 FROM identity.staff_users', '42501');
  PERFORM t.expect('SELECT 1 FROM identity.biometric_templates', '42501');
  PERFORM t.expect($$INSERT INTO audit.events (action, entity_type, outcome) VALUES ('x','y','success')$$, '42501');
  PERFORM t.expect('UPDATE audit.events SET outcome = ''success''', '42501');
  PERFORM t.expect('DELETE FROM audit.events', '42501');
  PERFORM t.expect('SELECT identity._require_staff(NULL, ARRAY[''reviewer''])', '42501');

  -- Submit enrolment: permissions and validation
  PERFORM t.expect(format($$SELECT * FROM identity.api_submit_enrolment(%L,%L,'A B','1990-01-01')$$, reviewer, centre1), '42501');
  PERFORM t.expect(format($$SELECT * FROM identity.api_submit_enrolment(%L,%L,'A B','1990-01-01')$$, provider, centre1), '42501');
  PERFORM t.expect(format($$SELECT * FROM identity.api_submit_enrolment(%L,%L,'A B','1990-01-01')$$, officer1, centre2), '42501');
  PERFORM t.expect(format($$SELECT * FROM identity.api_submit_enrolment(%L,%L,'A B','1990-01-01')$$, gen_random_uuid(), centre1), '42501');
  PERFORM t.expect(format($$SELECT * FROM identity.api_submit_enrolment(%L,%L,'  ','1990-01-01')$$, officer1, centre1), '22023');
  PERFORM t.expect(format($$SELECT * FROM identity.api_submit_enrolment(%L,%L,'A B','2999-01-01')$$, officer1, centre1), '22023');

  SELECT new_citizen_id, new_enrolment_id INTO c1, e1
    FROM identity.api_submit_enrolment(officer1, centre1, 'Test Person One', '1991-02-03', 'Lusaka', 'male', 'V', 'Lusaka');
  ASSERT c1 IS NOT NULL AND e1 IS NOT NULL, 'submit should return ids';

  -- Templates: permissions, supersede, atomic
  PERFORM t.expect(format($$SELECT identity.api_store_template(%L,%L,'iris',%L,'k1','v1',90)$$, officer2, c1, blob), '42501');
  PERFORM t.expect(format($$SELECT identity.api_store_template(%L,%L,'iris',%L,'k1','v1',90)$$, provider, c1, blob), '42501');
  PERFORM t.expect(format($$SELECT identity.api_store_template(%L,%L,'face',%L,'k1','v1',90)$$, officer1, c1, blob), '22023');
  PERFORM t.expect(format($$SELECT identity.api_store_template(%L,%L,'iris',''::bytea,'k1','v1',90)$$, officer1, c1), '22023');
  PERFORM identity.api_store_template(officer1, c1, 'fingerprint', blob, 'k1', 'v1', 88);
  PERFORM identity.api_store_template(officer1, c1, 'fingerprint', blob, 'k1', 'v1', 91);  -- supersedes the first
  RESET ROLE;
  SELECT count(*) INTO n FROM identity.biometric_templates WHERE citizen_id = c1 AND modality = 'fingerprint' AND status = 'active';
  ASSERT n = 1, 'exactly one active fingerprint template, got ' || n;
  SELECT count(*) INTO n FROM identity.biometric_templates WHERE citizen_id = c1 AND modality = 'fingerprint' AND status = 'superseded';
  ASSERT n = 1, 'old fingerprint template should be superseded, got ' || n;
  SET LOCAL ROLE identity_api;

  -- Approval needs both modalities
  PERFORM t.expect(format($$SELECT identity.api_decide_enrolment(%L,%L,'approve')$$, reviewer, e1), '55000');
  PERFORM identity.api_store_template(officer1, c1, 'iris', blob, 'k1', 'v1', 92);

  -- Gallery: restricted, audited
  PERFORM t.expect(format($$SELECT * FROM identity.api_get_gallery(%L,'iris',%L)$$, provider, c1), '42501');
  SELECT count(*) INTO n FROM identity.api_get_gallery(reviewer, 'iris', gen_random_uuid());
  ASSERT n = 1, 'gallery should release 1 iris template, got ' || n;

  -- Match flow: flag, block approval, review, approve
  PERFORM t.expect(format($$SELECT identity.api_record_match_case(%L,%L,%L,'iris',50)$$, officer2, e1, 'c1000000-0000-0000-0000-000000000001'), '42501');
  PERFORM t.expect(format($$SELECT identity.api_record_match_case(%L,%L,%L,'iris',50)$$, officer1, e1, c1), '22023');
  m1 := identity.api_record_match_case(officer1, e1, 'c1000000-0000-0000-0000-000000000001', 'iris', 91.5);
  ASSERT m1 IS NOT NULL, 'match case should be created';
  ASSERT identity.api_record_match_case(officer1, e1, 'c1000000-0000-0000-0000-000000000001', 'iris', 91.5) = m1, 'recording the same match twice returns the same case';
  PERFORM t.expect(format($$SELECT identity.api_decide_enrolment(%L,%L,'approve')$$, reviewer, e1), '55000');  -- flagged
  PERFORM t.expect(format($$SELECT identity.api_review_match(%L,%L,'false_match')$$, officer1, m1), '42501');
  PERFORM t.expect(format($$SELECT identity.api_review_match(%L,%L,'maybe')$$, reviewer, m1), '22023');
  PERFORM identity.api_review_match(reviewer, m1, 'false_match', 'different person');
  PERFORM t.expect(format($$SELECT identity.api_review_match(%L,%L,'false_match')$$, reviewer, m1), '55000');  -- already reviewed
  PERFORM t.expect(format($$SELECT identity.api_decide_enrolment(%L,%L,'approve')$$, officer1, e1), '42501');
  PERFORM t.expect(format($$SELECT identity.api_decide_enrolment(%L,%L,'reject')$$, reviewer, e1), '22023');  -- reason needed
  num := identity.api_decide_enrolment(reviewer, e1, 'approve');
  ASSERT num ~ '^[0-9]{6}/[0-9]{2}/[0-9]$', 'identity number format, got ' || coalesce(num, 'NULL');
  PERFORM t.expect(format($$SELECT identity.api_decide_enrolment(%L,%L,'approve')$$, reviewer, e1), '55000');  -- already decided

  -- Duplicate scenario: confirmed duplicate rejects the enrolment and closes other cases
  SELECT new_citizen_id, new_enrolment_id INTO c2, e2 FROM identity.api_submit_enrolment(officer1, centre1, 'Test Person Two', '1992-03-04');
  PERFORM identity.api_store_template(officer1, c2, 'fingerprint', blob, 'k1', 'v1', 80);
  PERFORM identity.api_store_template(officer1, c2, 'iris', blob, 'k1', 'v1', 80);
  m1 := identity.api_record_match_case(officer1, e2, c1, 'fingerprint', 97);
  m2 := identity.api_record_match_case(officer1, e2, 'c1000000-0000-0000-0000-000000000002', 'iris', 90);
  PERFORM identity.api_review_match(reviewer, m1, 'confirmed_duplicate', 'same fingerprint');

  -- Direct reject path and the backend audit hook
  SELECT new_citizen_id, new_enrolment_id INTO c3, e3 FROM identity.api_submit_enrolment(officer1, centre1, 'Test Person Three', '1993-04-05');
  PERFORM identity.api_decide_enrolment(reviewer, e3, 'reject', 'documents incomplete');
  PERFORM identity.api_write_audit(officer2, 'enrolment.update', 'enrolment', e1::text, 'denied', gen_random_uuid(), '10.0.0.9', '{"why":"test"}');
  PERFORM t.expect(format($$SELECT identity.api_write_audit(%L,'x','y','z','nonsense')$$, officer1), '23514');

  RESET ROLE;

  -- Final state checks (as the owner)
  ASSERT (SELECT status FROM identity.citizens WHERE citizen_id = c1) = 'active', 'c1 active';
  ASSERT (SELECT identity_number FROM identity.citizens WHERE citizen_id = c1) = num, 'c1 number stored';
  ASSERT (SELECT status FROM identity.enrolments WHERE enrolment_id = e2) = 'rejected', 'duplicate enrolment rejected';
  ASSERT (SELECT identity_number FROM identity.citizens WHERE citizen_id = c2) IS NULL, 'duplicate gets no identity number';
  ASSERT (SELECT status FROM identity.match_cases WHERE match_case_id = m2) = 'closed', 'other open case closed';
  ASSERT (SELECT status FROM identity.citizens WHERE citizen_id = c3) = 'pending', 'rejected citizen stays pending';
  ASSERT (SELECT status FROM identity.enrolments WHERE enrolment_id = e3) = 'rejected', 'e3 rejected';
  SELECT count(*) INTO n FROM audit.events WHERE action = 'enrolment.approve' AND entity_id = e1::text AND outcome = 'success';
  ASSERT n = 1, 'approval audited';
  SELECT count(*) INTO n FROM audit.events WHERE action = 'biometrics.gallery_read' AND (details->>'released')::int = 1;
  ASSERT n = 1, 'gallery read audited with count';
  SELECT count(*) INTO n FROM audit.events WHERE outcome = 'denied' AND actor_role = 'registration_officer' AND action = 'enrolment.update';
  ASSERT n = 1, 'backend-recorded denial audited with actor role';
  SELECT count(*) INTO n FROM audit.events WHERE details::text LIKE '%abab%';
  ASSERT n = 0, 'no biometric bytes in audit details';

  RAISE NOTICE 'ALL API FUNCTION TESTS PASSED';
END
$test$;

ROLLBACK;
