-- PROPOSED. Not applied. Review, then run once in the Supabase SQL editor.
-- Creates the application role with minimal rights. Writes will later be
-- granted ONLY as EXECUTE on specific functions, not as table privileges.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'identity_api') THEN
    CREATE ROLE identity_api LOGIN NOINHERIT;
  END IF;
END $$;

-- Set the password separately and never commit it:
--   ALTER ROLE identity_api PASSWORD '<generate a long random password>';
-- Via the Supabase pooler the username becomes: identity_api.<project-ref>

GRANT USAGE ON SCHEMA identity TO identity_api;
GRANT SELECT ON identity.registration_centres TO identity_api;

-- Pin search_path on the existing guard function (advisor warning).
ALTER FUNCTION identity.check_identity_number_assignment()
  SET search_path = pg_catalog, identity;

-- Optional hygiene (Supabase advisor): stop the API roles calling the
-- RLS auto-enable event-trigger function over RPC.
-- REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM PUBLIC, anon, authenticated;
