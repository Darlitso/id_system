-- APPLIED to Supabase project id_system (migration name: 003_enable_rls).
-- Turns on Row Level Security for every table in the identity and audit schemas.
-- With RLS on and no policy, API roles (anon, authenticated) can read nothing.
-- SECURITY DEFINER functions owned by the table owner still work (owners bypass RLS),
-- so do NOT use FORCE ROW LEVEL SECURITY unless those functions are redesigned.

ALTER TABLE audit.events                   ENABLE ROW LEVEL SECURITY;
ALTER TABLE identity.biometric_templates    ENABLE ROW LEVEL SECURITY;
ALTER TABLE identity.citizens               ENABLE ROW LEVEL SECURITY;
ALTER TABLE identity.credentials            ENABLE ROW LEVEL SECURITY;
ALTER TABLE identity.enrolments             ENABLE ROW LEVEL SECURITY;
ALTER TABLE identity.match_cases            ENABLE ROW LEVEL SECURITY;
ALTER TABLE identity.registration_centres   ENABLE ROW LEVEL SECURITY;
ALTER TABLE identity.staff_users            ENABLE ROW LEVEL SECURITY;
ALTER TABLE identity.verification_events    ENABLE ROW LEVEL SECURITY;

-- The app role may read centres (list for the enrolment form).
CREATE POLICY centres_read_api ON identity.registration_centres
  FOR SELECT TO identity_api USING (true);
