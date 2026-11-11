-- 005_auth_and_reads.sql
-- Login support and READ access for the backend, as functions only (same model as 004).
-- Every read function checks the acting staff member's role in the database.
-- Officers only see data tied to their own centre. Password hashes are released ONLY by
-- api_get_staff_login, and biometric ciphertext ONLY by api_get_gallery / api_verify_lookup (both audited).

-- ---------------------------------------------------------------------
-- Login (called before anyone is authenticated, so there is no actor yet)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION identity.api_get_staff_login(p_username text)
RETURNS TABLE (user_id uuid, username text, password_hash text, display_name text,
               role text, centre_id uuid, is_active boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, identity
AS $$
  SELECT s.user_id, s.username::text, s.password_hash, s.display_name::text, s.role, s.centre_id, s.is_active
    FROM identity.staff_users s
   WHERE s.username = p_username;
$$;

CREATE OR REPLACE FUNCTION identity.api_record_login(
  p_actor uuid, p_username text, p_ok boolean, p_request uuid DEFAULT NULL, p_ip inet DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, identity
AS $$
DECLARE
  v_role text;
BEGIN
  IF p_ok AND p_actor IS NOT NULL THEN
    UPDATE identity.staff_users SET last_login_at = now() WHERE user_id = p_actor;
  END IF;
  SELECT role INTO v_role FROM identity.staff_users WHERE user_id = p_actor;
  PERFORM identity._audit(p_actor, v_role, CASE WHEN p_ok THEN 'auth.login' ELSE 'auth.login_failed' END,
                          'staff_user', p_actor::text, CASE WHEN p_ok THEN 'success' ELSE 'failure' END,
                          p_request, p_ip, jsonb_build_object('username', left(coalesce(p_username, ''), 80)));
END;
$$;

-- ---------------------------------------------------------------------
-- One enrolment (the backend needs the citizen id and state before capturing biometrics)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION identity.api_get_enrolment(p_actor uuid, p_enrolment uuid)
RETURNS TABLE (enrolment_id uuid, citizen_id uuid, centre_id uuid, status text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, identity
AS $$
DECLARE
  s identity.staff_users;
BEGIN
  s := identity._require_staff(p_actor, ARRAY['registration_officer', 'reviewer', 'administrator']);
  RETURN QUERY
    SELECT e.enrolment_id, e.citizen_id, e.centre_id, e.status
      FROM identity.enrolments e
     WHERE e.enrolment_id = p_enrolment
       AND (s.role <> 'registration_officer' OR e.centre_id = s.centre_id);
END;
$$;

-- ---------------------------------------------------------------------
-- Lists
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION identity.api_list_enrolments(p_actor uuid, p_status text DEFAULT NULL)
RETURNS TABLE (enrolment_id uuid, citizen_id uuid, citizen_name text, centre_code text, status text,
               submitted_at timestamptz, decided_at timestamptz, decision_reason text,
               open_matches bigint, fingerprint_quality numeric, iris_quality numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, identity
AS $$
DECLARE
  s identity.staff_users;
BEGIN
  s := identity._require_staff(p_actor, ARRAY['registration_officer', 'reviewer', 'administrator']);
  RETURN QUERY
    SELECT e.enrolment_id, e.citizen_id, c.full_name::text, rc.centre_code::text, e.status,
           e.submitted_at, e.decided_at, e.decision_reason,
           (SELECT count(*) FROM identity.match_cases m WHERE m.enrolment_id = e.enrolment_id AND m.status = 'pending_review'),
           (SELECT t.quality_score FROM identity.biometric_templates t WHERE t.citizen_id = e.citizen_id AND t.modality = 'fingerprint' AND t.status = 'active'),
           (SELECT t.quality_score FROM identity.biometric_templates t WHERE t.citizen_id = e.citizen_id AND t.modality = 'iris' AND t.status = 'active')
      FROM identity.enrolments e
      JOIN identity.citizens c ON c.citizen_id = e.citizen_id
      JOIN identity.registration_centres rc ON rc.centre_id = e.centre_id
     WHERE (p_status IS NULL OR e.status = p_status)
       AND (s.role <> 'registration_officer' OR e.centre_id = s.centre_id)
     ORDER BY e.created_at DESC
     LIMIT 200;
END;
$$;

CREATE OR REPLACE FUNCTION identity.api_list_citizens(p_actor uuid, p_search text DEFAULT NULL)
RETURNS TABLE (citizen_id uuid, identity_number text, full_name text, date_of_birth date, district text,
               status text, fingerprint_quality numeric, iris_quality numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, identity
AS $$
DECLARE
  s identity.staff_users;
  q text := nullif(btrim(coalesce(p_search, '')), '');
BEGIN
  s := identity._require_staff(p_actor, ARRAY['registration_officer', 'reviewer', 'administrator', 'auditor']);
  RETURN QUERY
    SELECT c.citizen_id, c.identity_number::text, c.full_name::text, c.date_of_birth, c.district::text, c.status,
           (SELECT t.quality_score FROM identity.biometric_templates t WHERE t.citizen_id = c.citizen_id AND t.modality = 'fingerprint' AND t.status = 'active'),
           (SELECT t.quality_score FROM identity.biometric_templates t WHERE t.citizen_id = c.citizen_id AND t.modality = 'iris' AND t.status = 'active')
      FROM identity.citizens c
     WHERE (q IS NULL OR c.full_name ILIKE '%' || q || '%' OR c.identity_number ILIKE '%' || q || '%' OR c.district ILIKE '%' || q || '%')
       AND (s.role <> 'registration_officer' OR EXISTS (
             SELECT 1 FROM identity.enrolments e WHERE e.citizen_id = c.citizen_id AND e.centre_id = s.centre_id))
     ORDER BY c.created_at DESC
     LIMIT 200;
END;
$$;

CREATE OR REPLACE FUNCTION identity.api_list_match_cases(p_actor uuid, p_status text DEFAULT NULL)
RETURNS TABLE (match_case_id uuid, enrolment_id uuid, applicant_name text, candidate_name text,
               candidate_identity_number text, modality text, match_score numeric, status text,
               reviewed_by_name text, reviewed_at timestamptz, review_notes text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, identity
AS $$
BEGIN
  PERFORM identity._require_staff(p_actor, ARRAY['reviewer', 'administrator']);
  RETURN QUERY
    SELECT m.match_case_id, m.enrolment_id, a.full_name::text, k.full_name::text, k.identity_number::text,
           m.modality, m.match_score, m.status, u.display_name::text, m.reviewed_at, m.review_notes
      FROM identity.match_cases m
      JOIN identity.enrolments e ON e.enrolment_id = m.enrolment_id
      JOIN identity.citizens a ON a.citizen_id = e.citizen_id
      JOIN identity.citizens k ON k.citizen_id = m.candidate_citizen_id
      LEFT JOIN identity.staff_users u ON u.user_id = m.reviewed_by
     WHERE (p_status IS NULL OR m.status = p_status)
     ORDER BY m.created_at DESC
     LIMIT 200;
END;
$$;

CREATE OR REPLACE FUNCTION identity.api_list_audit(
  p_actor uuid, p_outcome text DEFAULT NULL, p_search text DEFAULT NULL, p_limit integer DEFAULT 100
) RETURNS TABLE (audit_id bigint, occurred_at timestamptz, actor_name text, actor_role text, action text,
                 entity_type text, entity_id text, outcome text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, identity, audit
AS $$
DECLARE
  q text := nullif(btrim(coalesce(p_search, '')), '');
BEGIN
  PERFORM identity._require_staff(p_actor, ARRAY['auditor', 'administrator']);
  RETURN QUERY
    SELECT a.audit_id, a.occurred_at, coalesce(u.username::text, '-'), a.actor_role, a.action::text,
           a.entity_type::text, a.entity_id, a.outcome
      FROM audit.events a
      LEFT JOIN identity.staff_users u ON u.user_id = a.actor_user_id
     WHERE (p_outcome IS NULL OR a.outcome = p_outcome)
       AND (q IS NULL OR a.action ILIKE '%' || q || '%' OR coalesce(u.username, '') ILIKE '%' || q || '%'
            OR coalesce(a.entity_id, '') ILIKE '%' || q || '%')
     ORDER BY a.audit_id DESC
     LIMIT least(greatest(coalesce(p_limit, 100), 1), 500);
END;
$$;

CREATE OR REPLACE FUNCTION identity.api_stats(p_actor uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, identity
AS $$
BEGIN
  PERFORM identity._require_staff(p_actor, ARRAY['registration_officer', 'reviewer', 'administrator', 'auditor']);
  RETURN jsonb_build_object(
    'citizens_total', (SELECT count(*) FROM identity.citizens),
    'queue', (SELECT count(*) FROM identity.enrolments WHERE status IN ('submitted', 'flagged')),
    'open_matches', (SELECT count(*) FROM identity.match_cases WHERE status = 'pending_review'),
    'verifications_total', (SELECT count(*) FROM identity.verification_events),
    'by_status', coalesce((SELECT jsonb_object_agg(status, n) FROM
                  (SELECT status, count(*) AS n FROM identity.citizens GROUP BY status) x), '{}'::jsonb),
    'enrolments_by_day', (SELECT jsonb_agg(jsonb_build_object('day', d::date, 'count',
                  (SELECT count(*) FROM identity.enrolments e WHERE e.created_at::date = d::date)) ORDER BY d)
                  FROM generate_series(current_date - 6, current_date, interval '1 day') d)
  );
END;
$$;

-- ---------------------------------------------------------------------
-- Verification by a service provider (1:1). The holder's encrypted fingerprint template is
-- released to the backend for comparison; the provider only ever receives a result.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION identity.api_verify_lookup(
  p_actor uuid, p_number text, p_request uuid DEFAULT NULL, p_ip inet DEFAULT NULL
) RETURNS TABLE (v_citizen_id uuid, v_name text, v_status text, v_ciphertext bytea, v_key_id text, v_version text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, identity
AS $$
DECLARE
  s identity.staff_users;
BEGIN
  s := identity._require_staff(p_actor, ARRAY['service_provider', 'administrator']);
  PERFORM identity._audit(p_actor, s.role, 'verify.lookup', 'citizen', NULL, 'success', p_request, p_ip,
                          jsonb_build_object('found', EXISTS (SELECT 1 FROM identity.citizens WHERE identity_number = p_number)));
  RETURN QUERY
    SELECT c.citizen_id, c.full_name::text, c.status, t.template_ciphertext, t.encryption_key_id, t.template_version::text
      FROM identity.citizens c
      LEFT JOIN identity.biometric_templates t
        ON t.citizen_id = c.citizen_id AND t.modality = 'fingerprint' AND t.status = 'active'
     WHERE c.identity_number = p_number;
END;
$$;

CREATE OR REPLACE FUNCTION identity.api_record_verification(
  p_actor uuid, p_citizen uuid, p_result text, p_reason text DEFAULT NULL,
  p_request uuid DEFAULT NULL, p_ip inet DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, identity
AS $$
DECLARE
  s identity.staff_users;
BEGIN
  s := identity._require_staff(p_actor, ARRAY['service_provider', 'administrator']);
  INSERT INTO identity.verification_events (provider_user_id, result, reason_code)
  VALUES (p_actor, p_result, left(p_reason, 60));
  PERFORM identity._audit(p_actor, s.role, 'verify.result', 'citizen', p_citizen::text,
                          CASE WHEN p_result = 'verified' THEN 'success' ELSE 'failure' END, p_request, p_ip,
                          jsonb_build_object('result', p_result, 'reason', p_reason));
END;
$$;

-- ---------------------------------------------------------------------
-- Permissions (same pattern as 004)
-- ---------------------------------------------------------------------
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA identity FROM PUBLIC;
DO $$
DECLARE
  r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA identity FROM %I', r);
    END IF;
  END LOOP;
END $$;

-- Grant EXECUTE on every api_* function (covers the ones added in this migration).
DO $$
DECLARE
  f record;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'identity' AND p.proname LIKE 'api\_%' LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO identity_api', f.sig);
  END LOOP;
END $$;
