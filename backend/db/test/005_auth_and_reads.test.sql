-- 005_auth_and_reads.test.sql
-- Behaviour tests for login and read functions, run AS identity_api.
-- Run ONLY on a throwaway/local test database after 000-005 and the dev seed. Rolled back at the end.
BEGIN;

CREATE SCHEMA t;
GRANT USAGE ON SCHEMA t TO identity_api;
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
  officer1 uuid := 'b1000000-0000-0000-0000-000000000001';  -- Lusaka
  officer2 uuid := 'b1000000-0000-0000-0000-000000000002';  -- Kitwe
  reviewer uuid := 'b1000000-0000-0000-0000-000000000004';
  provider uuid := 'b1000000-0000-0000-0000-000000000006';
  auditor  uuid := 'b1000000-0000-0000-0000-000000000007';
  n int; j jsonb; hash text;
BEGIN
  SET LOCAL ROLE identity_api;

  -- Login lookup
  SELECT password_hash INTO hash FROM identity.api_get_staff_login('officer.lusaka');
  ASSERT hash IS NOT NULL, 'login lookup returns the hash';
  SELECT count(*) INTO n FROM identity.api_get_staff_login('nobody');
  ASSERT n = 0, 'unknown user returns nothing';
  PERFORM identity.api_record_login(officer1, 'officer.lusaka', true, gen_random_uuid(), '10.0.0.5');
  PERFORM identity.api_record_login(NULL, 'nobody', false, gen_random_uuid(), '10.0.0.5');

  -- Enrolments: role and centre scoping
  PERFORM t.expect(format($$SELECT * FROM identity.api_list_enrolments(%L)$$, provider), '42501');
  PERFORM t.expect(format($$SELECT * FROM identity.api_list_enrolments(%L)$$, auditor), '42501');
  SELECT count(*) INTO n FROM identity.api_list_enrolments(reviewer);
  ASSERT n = 7, 'reviewer sees all 7 enrolments, got ' || n;
  SELECT count(*) INTO n FROM identity.api_list_enrolments(officer2);
  ASSERT n = 3, 'Kitwe officer sees only Kitwe enrolments, got ' || n;
  SELECT count(*) INTO n FROM identity.api_list_enrolments(reviewer, 'flagged');
  ASSERT n = 1, 'status filter works';
  SELECT count(*) INTO n FROM identity.api_get_enrolment(officer2, (SELECT enrolment_id FROM identity.api_list_enrolments(reviewer, 'submitted') LIMIT 1));
  ASSERT n = 0, 'officer cannot fetch another centre''s enrolment';

  -- Citizens
  PERFORM t.expect(format($$SELECT * FROM identity.api_list_citizens(%L)$$, provider), '42501');
  SELECT count(*) INTO n FROM identity.api_list_citizens(auditor);
  ASSERT n = 7, 'auditor sees the register, got ' || n;
  SELECT count(*) INTO n FROM identity.api_list_citizens(officer1);
  ASSERT n = 3, 'Lusaka officer sees only citizens enrolled at Lusaka, got ' || n;
  SELECT count(*) INTO n FROM identity.api_list_citizens(reviewer, 'phiri');
  ASSERT n = 1, 'search by name works';

  -- Match cases
  PERFORM t.expect(format($$SELECT * FROM identity.api_list_match_cases(%L)$$, officer1), '42501');
  SELECT count(*) INTO n FROM identity.api_list_match_cases(reviewer);
  ASSERT n = 2, 'reviewer sees match cases';

  -- Audit log
  PERFORM t.expect(format($$SELECT * FROM identity.api_list_audit(%L)$$, reviewer), '42501');
  SELECT count(*) INTO n FROM identity.api_list_audit(auditor, 'failure');
  ASSERT n >= 2, 'auditor sees failure events (seed + failed login)';
  SELECT count(*) INTO n FROM identity.api_list_audit(auditor, NULL, 'auth.login');
  ASSERT n >= 2, 'audit search works';

  -- Stats
  PERFORM t.expect(format($$SELECT identity.api_stats(%L)$$, provider), '42501');
  j := identity.api_stats(officer1);
  ASSERT (j->>'citizens_total')::int = 7 AND (j->>'queue')::int = 2 AND (j->>'open_matches')::int = 1, 'stats numbers';
  ASSERT jsonb_array_length(j->'enrolments_by_day') = 7, 'seven days of enrolments';

  -- Verification lookup (provider only) and result recording
  PERFORM t.expect(format($$SELECT * FROM identity.api_verify_lookup(%L,'100001/10/1')$$, officer1), '42501');
  SELECT count(*) INTO n FROM identity.api_verify_lookup(provider, '100001/10/1');
  ASSERT n = 1, 'holder found';
  SELECT count(*) INTO n FROM identity.api_verify_lookup(provider, '999999/10/1');
  ASSERT n = 0, 'unknown number returns nothing';
  PERFORM identity.api_record_verification(provider, 'c1000000-0000-0000-0000-000000000001', 'verified', NULL);
  PERFORM t.expect(format($$SELECT identity.api_record_verification(%L, NULL, 'banana')$$, provider), '23514');
  PERFORM t.expect(format($$SELECT identity.api_record_verification(%L, NULL, 'verified')$$, officer1), '42501');

  RESET ROLE;
  ASSERT (SELECT last_login_at FROM identity.staff_users WHERE user_id = officer1) IS NOT NULL, 'last_login_at set';
  ASSERT (SELECT count(*) FROM audit.events WHERE action = 'auth.login_failed') = 1, 'failed login audited';
  ASSERT (SELECT count(*) FROM audit.events WHERE action = 'verify.lookup') = 2, 'both lookups audited';
  ASSERT (SELECT count(*) FROM identity.verification_events WHERE result = 'verified') >= 1, 'verification recorded';

  RAISE NOTICE 'ALL 005 TESTS PASSED';
END
$test$;

ROLLBACK;
