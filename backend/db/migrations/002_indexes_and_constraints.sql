-- PROPOSED. Not applied. Non-destructive: only adds indexes, a trigger, and
-- partial unique indexes. Safe to run on empty tables; on tables with data,
-- the unique indexes fail if existing rows already violate them.

-- Foreign-key indexes
CREATE INDEX IF NOT EXISTS enrolments_centre_idx        ON identity.enrolments (centre_id);
CREATE INDEX IF NOT EXISTS enrolments_captured_by_idx   ON identity.enrolments (captured_by);
CREATE INDEX IF NOT EXISTS enrolments_decided_by_idx    ON identity.enrolments (decided_by) WHERE decided_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS match_cases_candidate_idx    ON identity.match_cases (candidate_citizen_id);
CREATE INDEX IF NOT EXISTS match_cases_reviewed_by_idx  ON identity.match_cases (reviewed_by) WHERE reviewed_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS biometric_captured_by_idx    ON identity.biometric_templates (captured_by);
CREATE INDEX IF NOT EXISTS credentials_revoked_by_idx   ON identity.credentials (revoked_by) WHERE revoked_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS staff_users_centre_idx       ON identity.staff_users (centre_id) WHERE centre_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS verification_events_cred_idx ON identity.verification_events (credential_id) WHERE credential_id IS NOT NULL;

-- Business rules
CREATE UNIQUE INDEX IF NOT EXISTS biometric_one_active_per_modality
  ON identity.biometric_templates (citizen_id, modality) WHERE status = 'active';
CREATE UNIQUE INDEX IF NOT EXISTS credentials_one_active_per_citizen
  ON identity.credentials (citizen_id) WHERE status = 'active';

-- DECISION NEEDED (uncomment if re-enrolment while one is open should be blocked):
-- CREATE UNIQUE INDEX IF NOT EXISTS enrolments_one_open_per_citizen
--   ON identity.enrolments (citizen_id)
--   WHERE status IN ('draft','submitted','matching','flagged');

-- Keep citizens.updated_at current
CREATE OR REPLACE FUNCTION identity.set_updated_at()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS citizens_set_updated_at ON identity.citizens;
CREATE TRIGGER citizens_set_updated_at
  BEFORE UPDATE ON identity.citizens
  FOR EACH ROW EXECUTE FUNCTION identity.set_updated_at();
