-- 004_api_functions.sql
-- Write access for the backend, as functions only.
--
-- The backend connects as identity_api, which has NO table privileges (see 001).
-- Every write goes through one of the identity.api_* functions below. Each function:
--   * runs as its owner (SECURITY DEFINER) with a pinned search_path,
--   * checks that the acting staff member exists, is active and has the right role
--     (and, for officers, works at the right centre), so the DATABASE enforces the
--     rules even if the backend has a bug,
--   * changes data and writes its audit event in ONE transaction,
--   * never returns or logs raw biometric data.
-- p_actor is the staff user_id the backend authenticated; p_request and p_ip are for the audit trail.

-- ---------------------------------------------------------------------
-- Identity numbers. Format is isolated here so it can change in ONE place.
-- Current format: 6 digits / 10 / 1  (confirm against the official NRC format).
-- ---------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS identity.identity_number_seq START 100001;

CREATE OR REPLACE FUNCTION identity.next_identity_number()
RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, identity
AS $$
DECLARE
  n text;
BEGIN
  LOOP
    n := lpad(nextval('identity.identity_number_seq')::text, 6, '0') || '/10/1';
    EXIT WHEN NOT EXISTS (SELECT 1 FROM identity.citizens WHERE identity_number = n);
  END LOOP;
  RETURN n;
END;
$$;

-- ---------------------------------------------------------------------
-- Internal helpers (not granted to the API role)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION identity._require_staff(p_actor uuid, p_roles text[])
RETURNS identity.staff_users
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, identity
AS $$
DECLARE
  s identity.staff_users;
BEGIN
  SELECT * INTO s FROM identity.staff_users WHERE user_id = p_actor AND is_active;
  IF NOT FOUND OR NOT (s.role = ANY (p_roles)) THEN
    RAISE EXCEPTION 'not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN s;
END;
$$;

CREATE OR REPLACE FUNCTION identity._audit(
  p_actor uuid, p_role text, p_action text, p_entity_type text, p_entity_id text,
  p_outcome text, p_request uuid, p_ip inet, p_details jsonb
) RETURNS void
LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog, audit
AS $$
  INSERT INTO audit.events
    (actor_user_id, actor_role, action, entity_type, entity_id, request_id, outcome, source_ip, details)
  VALUES
    (p_actor, p_role, p_action, p_entity_type, p_entity_id, p_request, p_outcome, p_ip, coalesce(p_details, '{}'::jsonb));
$$;

-- ---------------------------------------------------------------------
-- 1. Submit an enrolment (creates a pending citizen + a submitted enrolment)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION identity.api_submit_enrolment(
  p_actor uuid, p_centre uuid, p_full_name text, p_date_of_birth date,
  p_place_of_birth text DEFAULT NULL, p_gender text DEFAULT NULL, p_village text DEFAULT NULL,
  p_district text DEFAULT NULL, p_chief text DEFAULT NULL, p_address text DEFAULT NULL,
  p_request uuid DEFAULT NULL, p_ip inet DEFAULT NULL
) RETURNS TABLE (new_citizen_id uuid, new_enrolment_id uuid)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, identity
AS $$
DECLARE
  s identity.staff_users;
  v_citizen uuid;
  v_enrolment uuid;
BEGIN
  s := identity._require_staff(p_actor, ARRAY['registration_officer', 'administrator']);
  IF s.role = 'registration_officer' AND s.centre_id IS DISTINCT FROM p_centre THEN
    RAISE EXCEPTION 'officers may only enrol at their own centre' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM identity.registration_centres WHERE centre_id = p_centre) THEN
    RAISE EXCEPTION 'unknown registration centre' USING ERRCODE = '23503';
  END IF;
  IF btrim(coalesce(p_full_name, '')) = '' THEN
    RAISE EXCEPTION 'full name is required' USING ERRCODE = '22023';
  END IF;
  IF p_date_of_birth IS NULL OR p_date_of_birth > current_date THEN
    RAISE EXCEPTION 'date of birth must be a past date' USING ERRCODE = '22023';
  END IF;

  INSERT INTO identity.citizens
    (full_name, date_of_birth, place_of_birth, gender_code, village, district, chief, address_text, registration_date)
  VALUES
    (btrim(p_full_name), p_date_of_birth, p_place_of_birth, p_gender, p_village, p_district, p_chief, p_address, current_date)
  RETURNING citizen_id INTO v_citizen;

  INSERT INTO identity.enrolments (citizen_id, centre_id, captured_by, status, submitted_at)
  VALUES (v_citizen, p_centre, p_actor, 'submitted', now())
  RETURNING enrolment_id INTO v_enrolment;

  PERFORM identity._audit(p_actor, s.role, 'enrolment.submit', 'enrolment', v_enrolment::text, 'success',
                          p_request, p_ip, jsonb_build_object('citizen_id', v_citizen, 'centre_id', p_centre));
  RETURN QUERY SELECT v_citizen, v_enrolment;
END;
$$;

-- ---------------------------------------------------------------------
-- 2. Store an ENCRYPTED biometric template (replaces the direct SQL in templateStore.js)
--    Supersedes any active template for the same citizen + modality, atomically.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION identity.api_store_template(
  p_actor uuid, p_citizen uuid, p_modality text, p_ciphertext bytea, p_key_id text,
  p_version text, p_quality numeric DEFAULT NULL, p_request uuid DEFAULT NULL, p_ip inet DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, identity
AS $$
DECLARE
  s identity.staff_users;
  v_status text;
  v_template uuid;
BEGIN
  s := identity._require_staff(p_actor, ARRAY['registration_officer', 'administrator']);
  IF p_modality NOT IN ('fingerprint', 'iris') THEN
    RAISE EXCEPTION 'unsupported modality' USING ERRCODE = '22023';
  END IF;
  IF p_ciphertext IS NULL OR octet_length(p_ciphertext) = 0 OR coalesce(p_key_id, '') = '' OR coalesce(p_version, '') = '' THEN
    RAISE EXCEPTION 'ciphertext, key id and template version are required' USING ERRCODE = '22023';
  END IF;

  SELECT status INTO v_status FROM identity.citizens WHERE citizen_id = p_citizen FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown citizen' USING ERRCODE = '23503';
  END IF;
  IF v_status <> 'pending' THEN
    RAISE EXCEPTION 'templates can only be captured while the citizen is pending' USING ERRCODE = '55000';
  END IF;
  IF s.role = 'registration_officer' AND NOT EXISTS (
       SELECT 1 FROM identity.enrolments WHERE citizen_id = p_citizen AND centre_id = s.centre_id) THEN
    RAISE EXCEPTION 'citizen is not enrolled at your centre' USING ERRCODE = '42501';
  END IF;

  UPDATE identity.biometric_templates SET status = 'superseded'
   WHERE citizen_id = p_citizen AND modality = p_modality AND status = 'active';

  INSERT INTO identity.biometric_templates
    (citizen_id, modality, template_ciphertext, encryption_key_id, template_version, quality_score, captured_by)
  VALUES (p_citizen, p_modality, p_ciphertext, p_key_id, p_version, p_quality, p_actor)
  RETURNING template_id INTO v_template;

  PERFORM identity._audit(p_actor, s.role, 'biometrics.store', 'biometric_template', v_template::text, 'success',
                          p_request, p_ip, jsonb_build_object('citizen_id', p_citizen, 'modality', p_modality,
                                                              'template_version', p_version, 'key_id', p_key_id));
  RETURN v_template;
END;
$$;

-- ---------------------------------------------------------------------
-- 3. Read the gallery for duplicate search (encrypted; the backend decrypts and matches).
--    Every call is audited with the number of templates released.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION identity.api_get_gallery(
  p_actor uuid, p_modality text, p_exclude_citizen uuid,
  p_request uuid DEFAULT NULL, p_ip inet DEFAULT NULL
) RETURNS TABLE (g_citizen_id uuid, g_ciphertext bytea, g_key_id text, g_version text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, identity
AS $$
DECLARE
  s identity.staff_users;
  n integer;
BEGIN
  s := identity._require_staff(p_actor, ARRAY['registration_officer', 'reviewer', 'administrator']);
  IF p_modality NOT IN ('fingerprint', 'iris') THEN
    RAISE EXCEPTION 'unsupported modality' USING ERRCODE = '22023';
  END IF;

  SELECT count(*) INTO n FROM identity.biometric_templates t
   WHERE t.status = 'active' AND t.modality = p_modality
     AND t.template_ciphertext IS NOT NULL AND t.citizen_id <> p_exclude_citizen;

  PERFORM identity._audit(p_actor, s.role, 'biometrics.gallery_read', 'biometric_template', NULL, 'success',
                          p_request, p_ip, jsonb_build_object('modality', p_modality, 'released', n));

  RETURN QUERY
    SELECT t.citizen_id, t.template_ciphertext, t.encryption_key_id, t.template_version::text
      FROM identity.biometric_templates t
     WHERE t.status = 'active' AND t.modality = p_modality
       AND t.template_ciphertext IS NOT NULL AND t.citizen_id <> p_exclude_citizen;
END;
$$;

-- ---------------------------------------------------------------------
-- 4. Record a possible duplicate for human review; flags the enrolment
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION identity.api_record_match_case(
  p_actor uuid, p_enrolment uuid, p_candidate uuid, p_modality text, p_score numeric,
  p_request uuid DEFAULT NULL, p_ip inet DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, identity
AS $$
DECLARE
  s identity.staff_users;
  e identity.enrolments;
  v_case uuid;
BEGIN
  s := identity._require_staff(p_actor, ARRAY['registration_officer', 'reviewer', 'administrator']);
  SELECT * INTO e FROM identity.enrolments WHERE enrolment_id = p_enrolment FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown enrolment' USING ERRCODE = '23503';
  END IF;
  IF s.role = 'registration_officer' AND e.centre_id IS DISTINCT FROM s.centre_id THEN
    RAISE EXCEPTION 'enrolment belongs to another centre' USING ERRCODE = '42501';
  END IF;
  IF e.status NOT IN ('submitted', 'matching', 'flagged') THEN
    RAISE EXCEPTION 'enrolment is not open' USING ERRCODE = '55000';
  END IF;
  IF p_candidate = e.citizen_id THEN
    RAISE EXCEPTION 'a citizen cannot be a duplicate of themselves' USING ERRCODE = '22023';
  END IF;

  INSERT INTO identity.match_cases (enrolment_id, candidate_citizen_id, modality, match_score)
  VALUES (p_enrolment, p_candidate, p_modality, p_score)
  ON CONFLICT (enrolment_id, candidate_citizen_id, modality) DO NOTHING
  RETURNING match_case_id INTO v_case;
  IF v_case IS NULL THEN
    SELECT match_case_id INTO v_case FROM identity.match_cases
     WHERE enrolment_id = p_enrolment AND candidate_citizen_id = p_candidate AND modality = p_modality;
  END IF;

  UPDATE identity.enrolments SET status = 'flagged'
   WHERE enrolment_id = p_enrolment AND status IN ('submitted', 'matching');

  PERFORM identity._audit(p_actor, s.role, 'match.record', 'match_case', v_case::text, 'success',
                          p_request, p_ip, jsonb_build_object('enrolment_id', p_enrolment,
                          'candidate_citizen_id', p_candidate, 'modality', p_modality, 'score', p_score));
  RETURN v_case;
END;
$$;

-- ---------------------------------------------------------------------
-- 5. A reviewer resolves a match case
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION identity.api_review_match(
  p_actor uuid, p_match uuid, p_decision text, p_notes text DEFAULT NULL,
  p_request uuid DEFAULT NULL, p_ip inet DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, identity
AS $$
DECLARE
  s identity.staff_users;
  m identity.match_cases;
BEGIN
  s := identity._require_staff(p_actor, ARRAY['reviewer', 'administrator']);
  IF p_decision NOT IN ('confirmed_duplicate', 'false_match', 'inconclusive') THEN
    RAISE EXCEPTION 'invalid decision' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO m FROM identity.match_cases WHERE match_case_id = p_match FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown match case' USING ERRCODE = '23503';
  END IF;
  IF m.status <> 'pending_review' THEN
    RAISE EXCEPTION 'match case already reviewed' USING ERRCODE = '55000';
  END IF;

  UPDATE identity.match_cases
     SET status = p_decision, reviewed_by = p_actor, reviewed_at = now(), review_notes = p_notes
   WHERE match_case_id = p_match;

  IF p_decision = 'confirmed_duplicate' THEN
    UPDATE identity.enrolments
       SET status = 'rejected', decided_at = now(), decided_by = p_actor,
           decision_reason = 'Confirmed biometric duplicate of citizen ' || m.candidate_citizen_id::text
     WHERE enrolment_id = m.enrolment_id AND status IN ('submitted', 'matching', 'flagged');
    UPDATE identity.match_cases
       SET status = 'closed', reviewed_by = p_actor, reviewed_at = now(),
           review_notes = 'Closed: enrolment rejected as duplicate'
     WHERE enrolment_id = m.enrolment_id AND status = 'pending_review';
  ELSIF NOT EXISTS (SELECT 1 FROM identity.match_cases
                     WHERE enrolment_id = m.enrolment_id AND status = 'pending_review') THEN
    UPDATE identity.enrolments SET status = 'submitted'
     WHERE enrolment_id = m.enrolment_id AND status = 'flagged';
  END IF;

  PERFORM identity._audit(p_actor, s.role, 'match.review', 'match_case', p_match::text, 'success',
                          p_request, p_ip, jsonb_build_object('decision', p_decision, 'enrolment_id', m.enrolment_id));
END;
$$;

-- ---------------------------------------------------------------------
-- 6. Approve or reject an enrolment. Approval issues the identity number.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION identity.api_decide_enrolment(
  p_actor uuid, p_enrolment uuid, p_decision text, p_reason text DEFAULT NULL,
  p_request uuid DEFAULT NULL, p_ip inet DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, identity
AS $$
DECLARE
  s identity.staff_users;
  e identity.enrolments;
  v_number text;
BEGIN
  s := identity._require_staff(p_actor, ARRAY['reviewer', 'administrator']);
  IF p_decision NOT IN ('approve', 'reject') THEN
    RAISE EXCEPTION 'invalid decision' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO e FROM identity.enrolments WHERE enrolment_id = p_enrolment FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown enrolment' USING ERRCODE = '23503';
  END IF;
  IF e.status <> 'submitted' THEN
    RAISE EXCEPTION 'only submitted enrolments can be decided (flagged ones need their match cases resolved first)'
      USING ERRCODE = '55000';
  END IF;

  IF p_decision = 'reject' THEN
    IF btrim(coalesce(p_reason, '')) = '' THEN
      RAISE EXCEPTION 'a reason is required to reject' USING ERRCODE = '22023';
    END IF;
    UPDATE identity.enrolments
       SET status = 'rejected', decided_at = now(), decided_by = p_actor, decision_reason = p_reason
     WHERE enrolment_id = p_enrolment;
    PERFORM identity._audit(p_actor, s.role, 'enrolment.reject', 'enrolment', p_enrolment::text, 'success',
                            p_request, p_ip, jsonb_build_object('reason', p_reason));
    RETURN NULL;
  END IF;

  IF EXISTS (SELECT 1 FROM identity.match_cases WHERE enrolment_id = p_enrolment AND status = 'pending_review') THEN
    RAISE EXCEPTION 'open match cases must be resolved first' USING ERRCODE = '55000';
  END IF;
  IF (SELECT count(DISTINCT modality) FROM identity.biometric_templates
       WHERE citizen_id = e.citizen_id AND status = 'active' AND modality IN ('fingerprint', 'iris')) < 2 THEN
    RAISE EXCEPTION 'fingerprint and iris templates must both be captured before approval' USING ERRCODE = '55000';
  END IF;

  v_number := identity.next_identity_number();
  UPDATE identity.citizens SET identity_number = v_number, status = 'active' WHERE citizen_id = e.citizen_id;
  UPDATE identity.enrolments
     SET status = 'approved', decided_at = now(), decided_by = p_actor, decision_reason = p_reason
   WHERE enrolment_id = p_enrolment;

  PERFORM identity._audit(p_actor, s.role, 'enrolment.approve', 'enrolment', p_enrolment::text, 'success',
                          p_request, p_ip, jsonb_build_object('citizen_id', e.citizen_id, 'identity_number', v_number));
  RETURN v_number;
END;
$$;

-- ---------------------------------------------------------------------
-- 7. Let the backend record denied / failed events it detects itself
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION identity.api_write_audit(
  p_actor uuid, p_action text, p_entity_type text, p_entity_id text, p_outcome text,
  p_request uuid DEFAULT NULL, p_ip inet DEFAULT NULL, p_details jsonb DEFAULT '{}'::jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, identity
AS $$
DECLARE
  v_role text;
BEGIN
  IF pg_column_size(coalesce(p_details, '{}'::jsonb)) > 8192 THEN
    RAISE EXCEPTION 'audit details too large' USING ERRCODE = '22023';
  END IF;
  SELECT role INTO v_role FROM identity.staff_users WHERE user_id = p_actor;
  PERFORM identity._audit(p_actor, v_role, p_action, p_entity_type, p_entity_id, p_outcome, p_request, p_ip, p_details);
END;
$$;

-- ---------------------------------------------------------------------
-- Permissions: nothing is executable by default; only the seven api_* functions go to identity_api.
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

GRANT EXECUTE ON FUNCTION
  identity.api_submit_enrolment(uuid, uuid, text, date, text, text, text, text, text, text, uuid, inet),
  identity.api_store_template(uuid, uuid, text, bytea, text, text, numeric, uuid, inet),
  identity.api_get_gallery(uuid, text, uuid, uuid, inet),
  identity.api_record_match_case(uuid, uuid, uuid, text, numeric, uuid, inet),
  identity.api_review_match(uuid, uuid, text, text, uuid, inet),
  identity.api_decide_enrolment(uuid, uuid, text, text, uuid, inet),
  identity.api_write_audit(uuid, text, text, text, text, uuid, inet, jsonb)
TO identity_api;
