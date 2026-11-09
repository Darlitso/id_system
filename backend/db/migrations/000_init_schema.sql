-- 000_init_schema.sql
-- Base schema for the digital identity system (schemas: identity, audit).
-- Generated from the working local identity_db and verified against Supabase project id_system.
-- Run FIRST, on an empty database, before 001-003.
-- Removed on purpose: ownership statements and grants to local-only roles
-- (identity_app_permissions, claude_reader). Access is defined in 001 and later migrations.
-- Data is never stored in migrations. Dev data lives in db/seed/seed_dev.sql.


CREATE SCHEMA audit;

CREATE SCHEMA identity;

CREATE FUNCTION identity.check_identity_number_assignment() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Once assigned, an identity number cannot be
    -- replaced or removed through an UPDATE.
    IF OLD.identity_number IS NOT NULL
       AND NEW.identity_number IS DISTINCT FROM OLD.identity_number
    THEN
        RAISE EXCEPTION
            'An assigned identity number cannot be changed or removed';
    END IF;

    -- A new identity number can only be assigned
    -- when the citizen is active.
    IF OLD.identity_number IS NULL
       AND NEW.identity_number IS NOT NULL
       AND NEW.status <> 'active'
    THEN
        RAISE EXCEPTION
            'Identity number may only be assigned when citizen status is active';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TABLE audit.events (
    audit_id bigint NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    actor_user_id uuid,
    actor_role text,
    action character varying(100) NOT NULL,
    entity_type character varying(100) NOT NULL,
    entity_id text,
    request_id uuid,
    outcome text NOT NULL,
    source_ip inet,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT events_outcome_check CHECK ((outcome = ANY (ARRAY['success'::text, 'denied'::text, 'failure'::text])))
);

ALTER TABLE audit.events ALTER COLUMN audit_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME audit.events_audit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE identity.biometric_templates (
    template_id uuid DEFAULT gen_random_uuid() NOT NULL,
    citizen_id uuid NOT NULL,
    modality text NOT NULL,
    template_ciphertext bytea,
    object_key text,
    encryption_key_id text NOT NULL,
    template_version character varying(40) NOT NULL,
    quality_score numeric(5,2),
    status text DEFAULT 'active'::text NOT NULL,
    captured_at timestamp with time zone DEFAULT now() NOT NULL,
    captured_by uuid NOT NULL,
    CONSTRAINT biometric_templates_check CHECK ((((template_ciphertext IS NOT NULL) AND (object_key IS NULL)) OR ((template_ciphertext IS NULL) AND (object_key IS NOT NULL)))),
    CONSTRAINT biometric_templates_modality_check CHECK ((modality = ANY (ARRAY['fingerprint'::text, 'iris'::text]))),
    CONSTRAINT biometric_templates_quality_score_check CHECK (((quality_score >= (0)::numeric) AND (quality_score <= (100)::numeric))),
    CONSTRAINT biometric_templates_status_check CHECK ((status = ANY (ARRAY['active'::text, 'superseded'::text, 'revoked'::text])))
);

CREATE TABLE identity.citizens (
    citizen_id uuid DEFAULT gen_random_uuid() NOT NULL,
    identity_number character varying(40),
    full_name character varying(200) NOT NULL,
    date_of_birth date NOT NULL,
    place_of_birth character varying(120),
    gender_code character varying(30),
    village character varying(120),
    district character varying(120),
    chief character varying(120),
    registration_date date NOT NULL,
    address_text text,
    photo_object_key text,
    status text DEFAULT 'pending'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT citizens_check CHECK (((identity_number IS NULL) OR (status = ANY (ARRAY['active'::text, 'suspended'::text, 'deceased'::text, 'revoked'::text])))),
    CONSTRAINT citizens_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'active'::text, 'suspended'::text, 'deceased'::text, 'revoked'::text])))
);

CREATE TABLE identity.credentials (
    credential_id uuid DEFAULT gen_random_uuid() NOT NULL,
    citizen_id uuid NOT NULL,
    token_id uuid DEFAULT gen_random_uuid() NOT NULL,
    token_hash bytea NOT NULL,
    signature_algorithm character varying(40) NOT NULL,
    signing_key_id character varying(120) NOT NULL,
    issued_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone,
    status text DEFAULT 'active'::text NOT NULL,
    revoked_at timestamp with time zone,
    revoked_by uuid,
    revocation_reason text,
    CONSTRAINT credentials_check CHECK (((expires_at IS NULL) OR (expires_at > issued_at))),
    CONSTRAINT credentials_check1 CHECK (((status <> 'revoked'::text) OR (revoked_at IS NOT NULL))),
    CONSTRAINT credentials_status_check CHECK ((status = ANY (ARRAY['active'::text, 'revoked'::text, 'expired'::text, 'superseded'::text])))
);

CREATE VIEW identity.credential_verification_status AS
 SELECT c.token_id,
    c.status,
    c.issued_at,
    c.expires_at,
    p.identity_number,
    p.status AS citizen_status
   FROM (identity.credentials c
     JOIN identity.citizens p ON ((p.citizen_id = c.citizen_id)));

CREATE TABLE identity.enrolments (
    enrolment_id uuid DEFAULT gen_random_uuid() NOT NULL,
    citizen_id uuid NOT NULL,
    centre_id uuid NOT NULL,
    captured_by uuid NOT NULL,
    status text DEFAULT 'submitted'::text NOT NULL,
    submitted_at timestamp with time zone,
    decided_at timestamp with time zone,
    decided_by uuid,
    decision_reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT enrolments_check CHECK (((status <> ALL (ARRAY['approved'::text, 'rejected'::text])) OR (decided_at IS NOT NULL))),
    CONSTRAINT enrolments_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'submitted'::text, 'matching'::text, 'flagged'::text, 'approved'::text, 'rejected'::text, 'cancelled'::text])))
);

CREATE TABLE identity.match_cases (
    match_case_id uuid DEFAULT gen_random_uuid() NOT NULL,
    enrolment_id uuid NOT NULL,
    candidate_citizen_id uuid NOT NULL,
    modality text NOT NULL,
    match_score numeric(7,4),
    status text DEFAULT 'pending_review'::text NOT NULL,
    reviewed_by uuid,
    reviewed_at timestamp with time zone,
    review_notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT match_cases_check CHECK ((((status = 'pending_review'::text) AND (reviewed_at IS NULL)) OR ((status <> 'pending_review'::text) AND (reviewed_at IS NOT NULL)))),
    CONSTRAINT match_cases_match_score_check CHECK (((match_score >= (0)::numeric) AND (match_score <= (100)::numeric))),
    CONSTRAINT match_cases_modality_check CHECK ((modality = ANY (ARRAY['fingerprint'::text, 'iris'::text, 'combined'::text]))),
    CONSTRAINT match_cases_status_check CHECK ((status = ANY (ARRAY['pending_review'::text, 'confirmed_duplicate'::text, 'false_match'::text, 'inconclusive'::text, 'closed'::text])))
);

CREATE TABLE identity.registration_centres (
    centre_id uuid DEFAULT gen_random_uuid() NOT NULL,
    centre_code character varying(30) NOT NULL,
    name character varying(160) NOT NULL,
    district character varying(120) NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE identity.staff_users (
    user_id uuid DEFAULT gen_random_uuid() NOT NULL,
    username character varying(80) NOT NULL,
    password_hash text NOT NULL,
    display_name character varying(160) NOT NULL,
    role text NOT NULL,
    centre_id uuid,
    is_active boolean DEFAULT true NOT NULL,
    mfa_enabled boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    last_login_at timestamp with time zone,
    CONSTRAINT staff_users_check CHECK (((role <> 'registration_officer'::text) OR (centre_id IS NOT NULL))),
    CONSTRAINT staff_users_role_check CHECK ((role = ANY (ARRAY['registration_officer'::text, 'reviewer'::text, 'administrator'::text, 'service_provider'::text, 'auditor'::text])))
);

CREATE TABLE identity.verification_events (
    verification_id uuid DEFAULT gen_random_uuid() NOT NULL,
    credential_id uuid,
    provider_user_id uuid,
    token_id uuid,
    result text NOT NULL,
    reason_code character varying(60),
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT verification_events_result_check CHECK ((result = ANY (ARRAY['verified'::text, 'not_verified'::text, 'revoked'::text, 'expired'::text, 'invalid_signature'::text, 'error'::text])))
);

ALTER TABLE ONLY audit.events
    ADD CONSTRAINT events_pkey PRIMARY KEY (audit_id);

ALTER TABLE ONLY identity.biometric_templates
    ADD CONSTRAINT biometric_templates_pkey PRIMARY KEY (template_id);

ALTER TABLE ONLY identity.citizens
    ADD CONSTRAINT citizens_identity_number_key UNIQUE (identity_number);

ALTER TABLE ONLY identity.citizens
    ADD CONSTRAINT citizens_pkey PRIMARY KEY (citizen_id);

ALTER TABLE ONLY identity.credentials
    ADD CONSTRAINT credentials_pkey PRIMARY KEY (credential_id);

ALTER TABLE ONLY identity.credentials
    ADD CONSTRAINT credentials_token_hash_key UNIQUE (token_hash);

ALTER TABLE ONLY identity.credentials
    ADD CONSTRAINT credentials_token_id_key UNIQUE (token_id);

ALTER TABLE ONLY identity.enrolments
    ADD CONSTRAINT enrolments_pkey PRIMARY KEY (enrolment_id);

ALTER TABLE ONLY identity.match_cases
    ADD CONSTRAINT match_cases_enrolment_id_candidate_citizen_id_modality_key UNIQUE (enrolment_id, candidate_citizen_id, modality);

ALTER TABLE ONLY identity.match_cases
    ADD CONSTRAINT match_cases_pkey PRIMARY KEY (match_case_id);

ALTER TABLE ONLY identity.registration_centres
    ADD CONSTRAINT registration_centres_centre_code_key UNIQUE (centre_code);

ALTER TABLE ONLY identity.registration_centres
    ADD CONSTRAINT registration_centres_pkey PRIMARY KEY (centre_id);

ALTER TABLE ONLY identity.staff_users
    ADD CONSTRAINT staff_users_pkey PRIMARY KEY (user_id);

ALTER TABLE ONLY identity.staff_users
    ADD CONSTRAINT staff_users_username_key UNIQUE (username);

ALTER TABLE ONLY identity.verification_events
    ADD CONSTRAINT verification_events_pkey PRIMARY KEY (verification_id);

CREATE INDEX audit_events_actor_time_idx ON audit.events USING btree (actor_user_id, occurred_at DESC);

CREATE INDEX audit_events_entity_idx ON audit.events USING btree (entity_type, entity_id);

CREATE INDEX audit_events_time_idx ON audit.events USING btree (occurred_at DESC);

CREATE INDEX biometric_citizen_modality_idx ON identity.biometric_templates USING btree (citizen_id, modality, status);

CREATE INDEX credentials_citizen_status_idx ON identity.credentials USING btree (citizen_id, status);

CREATE INDEX enrolments_citizen_created_idx ON identity.enrolments USING btree (citizen_id, created_at DESC);

CREATE INDEX enrolments_status_created_idx ON identity.enrolments USING btree (status, created_at);

CREATE INDEX match_cases_review_queue_idx ON identity.match_cases USING btree (status, created_at) WHERE (status = 'pending_review'::text);

CREATE INDEX verification_events_provider_time_idx ON identity.verification_events USING btree (provider_user_id, occurred_at DESC);

CREATE INDEX verification_events_time_idx ON identity.verification_events USING btree (occurred_at DESC);

CREATE TRIGGER citizens_identity_number_guard BEFORE UPDATE OF identity_number, status ON identity.citizens FOR EACH ROW EXECUTE FUNCTION identity.check_identity_number_assignment();

ALTER TABLE ONLY identity.biometric_templates
    ADD CONSTRAINT biometric_templates_captured_by_fkey FOREIGN KEY (captured_by) REFERENCES identity.staff_users(user_id) ON DELETE RESTRICT;

ALTER TABLE ONLY identity.biometric_templates
    ADD CONSTRAINT biometric_templates_citizen_id_fkey FOREIGN KEY (citizen_id) REFERENCES identity.citizens(citizen_id) ON DELETE RESTRICT;

ALTER TABLE ONLY identity.credentials
    ADD CONSTRAINT credentials_citizen_id_fkey FOREIGN KEY (citizen_id) REFERENCES identity.citizens(citizen_id) ON DELETE RESTRICT;

ALTER TABLE ONLY identity.credentials
    ADD CONSTRAINT credentials_revoked_by_fkey FOREIGN KEY (revoked_by) REFERENCES identity.staff_users(user_id) ON DELETE RESTRICT;

ALTER TABLE ONLY identity.enrolments
    ADD CONSTRAINT enrolments_captured_by_fkey FOREIGN KEY (captured_by) REFERENCES identity.staff_users(user_id) ON DELETE RESTRICT;

ALTER TABLE ONLY identity.enrolments
    ADD CONSTRAINT enrolments_centre_id_fkey FOREIGN KEY (centre_id) REFERENCES identity.registration_centres(centre_id) ON DELETE RESTRICT;

ALTER TABLE ONLY identity.enrolments
    ADD CONSTRAINT enrolments_citizen_id_fkey FOREIGN KEY (citizen_id) REFERENCES identity.citizens(citizen_id) ON DELETE RESTRICT;

ALTER TABLE ONLY identity.enrolments
    ADD CONSTRAINT enrolments_decided_by_fkey FOREIGN KEY (decided_by) REFERENCES identity.staff_users(user_id) ON DELETE RESTRICT;

ALTER TABLE ONLY identity.match_cases
    ADD CONSTRAINT match_cases_candidate_citizen_id_fkey FOREIGN KEY (candidate_citizen_id) REFERENCES identity.citizens(citizen_id) ON DELETE RESTRICT;

ALTER TABLE ONLY identity.match_cases
    ADD CONSTRAINT match_cases_enrolment_id_fkey FOREIGN KEY (enrolment_id) REFERENCES identity.enrolments(enrolment_id) ON DELETE RESTRICT;

ALTER TABLE ONLY identity.match_cases
    ADD CONSTRAINT match_cases_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES identity.staff_users(user_id) ON DELETE RESTRICT;

ALTER TABLE ONLY identity.staff_users
    ADD CONSTRAINT staff_users_centre_id_fkey FOREIGN KEY (centre_id) REFERENCES identity.registration_centres(centre_id);

ALTER TABLE ONLY identity.verification_events
    ADD CONSTRAINT verification_events_credential_id_fkey FOREIGN KEY (credential_id) REFERENCES identity.credentials(credential_id) ON DELETE RESTRICT;

ALTER TABLE ONLY identity.verification_events
    ADD CONSTRAINT verification_events_provider_user_id_fkey FOREIGN KEY (provider_user_id) REFERENCES identity.staff_users(user_id) ON DELETE RESTRICT;

