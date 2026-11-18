-- Clinic Appointment System | PostgreSQL 17 | initial development schema and demo seed
-- Architecture: Clinic_Appointment_System_Architecture.md, sections 4 and 6, appendix A.
--
-- Run against an empty development database. From the project root in Ubuntu WSL:
--   sudo docker compose exec -T db psql -X -v ON_ERROR_STOP=1 -U clinic_app -d clinic_appointments < Clinic_Appointment_Database.sql
-- Use your Compose user/database names if they differ. The database user must be
-- allowed to create tables and install btree_gist. PostgreSQL 17's official image
-- includes that extension. The transaction rolls back on error.
--
-- This is a one-time bootstrap. It does not drop or reset an existing database.
-- Seed records are fictional and their email domains use the reserved .test suffix.
-- For Flyway, split the DDL into migrations and keep the demo seed in a dev-only
-- script/location. Spring Session and Spring Batch use their framework-supplied,
-- version-matched migrations. Apply those when you add the dependencies.
-- Application services own authorization, schedule locks, active-offering checks,
-- cutoff and horizon rules, local-day/grid validation, and workflow transitions.
-- Update updated_at / updated_by_user_id and row_version via the application.

BEGIN;

SET LOCAL search_path TO public, pg_catalog;
SET LOCAL TIME ZONE 'UTC';

CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;

-- Identity and clinic configuration

CREATE TABLE users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email_normalized varchar(320) NOT NULL UNIQUE
        CHECK (email_normalized = lower(btrim(email_normalized))
               AND email_normalized ~ '^[^[:space:]@]+@[^[:space:]@]+$'),
    display_name varchar(160) NOT NULL CHECK (btrim(display_name) <> ''),
    email_verified_at timestamptz,
    status varchar(16) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'DISABLED')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK (updated_at >= created_at),
    CHECK (email_verified_at IS NULL OR email_verified_at >= created_at)
);

CREATE TABLE staff_credentials (
    user_id uuid PRIMARY KEY REFERENCES users (id),
    password_hash text NOT NULL CHECK (btrim(password_hash) <> ''),
    changed_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE auth_challenges (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    destination_normalized varchar(320) NOT NULL
        CHECK (destination_normalized = lower(btrim(destination_normalized))
               AND destination_normalized ~ '^[^[:space:]@]+@[^[:space:]@]+$'),
    purpose varchar(24) NOT NULL CHECK (purpose IN ('PATIENT_SIGN_IN', 'STAFF_RECOVERY')),
    secret_digest bytea NOT NULL CHECK (octet_length(secret_digest) = 32),
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    max_attempts smallint NOT NULL DEFAULT 5 CHECK (max_attempts BETWEEN 1 AND 20),
    failed_attempts smallint NOT NULL DEFAULT 0 CHECK (failed_attempts BETWEEN 0 AND max_attempts),
    consumed_at timestamptz,
    superseded_at timestamptz,
    CHECK (expires_at > created_at),
    CHECK (consumed_at IS NULL OR consumed_at >= created_at AND consumed_at < expires_at),
    CHECK (superseded_at IS NULL OR superseded_at >= created_at),
    CHECK (num_nonnulls(consumed_at, superseded_at) <= 1)
);

-- Supersede any open challenge, including an expired one, before issuing a replacement.
CREATE UNIQUE INDEX auth_challenges_one_open
    ON auth_challenges (destination_normalized, purpose)
    WHERE consumed_at IS NULL AND superseded_at IS NULL;
CREATE INDEX auth_challenges_expires_idx ON auth_challenges (expires_at);

CREATE TABLE clinics (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug varchar(80) NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
    display_name varchar(160) NOT NULL CHECK (btrim(display_name) <> ''),
    status varchar(16) NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT', 'PUBLISHED')),
    booking_horizon_days smallint NOT NULL DEFAULT 30 CHECK (booking_horizon_days BETWEEN 1 AND 365),
    slot_step_minutes smallint NOT NULL DEFAULT 15 CHECK (slot_step_minutes BETWEEN 5 AND 60),
    min_lead_minutes integer NOT NULL DEFAULT 60 CHECK (min_lead_minutes >= 0),
    patient_change_cutoff_minutes integer NOT NULL DEFAULT 1440 CHECK (patient_change_cutoff_minutes >= 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    created_by_user_id uuid REFERENCES users (id),
    updated_by_user_id uuid REFERENCES users (id),
    CHECK (updated_at >= created_at)
);

CREATE TABLE branches (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    clinic_id uuid NOT NULL REFERENCES clinics (id),
    code varchar(24) NOT NULL CHECK (code ~ '^[A-Z0-9]+(-[A-Z0-9]+)*$'),
    name varchar(120) NOT NULL CHECK (btrim(name) <> ''),
    address_display varchar(255) NOT NULL CHECK (btrim(address_display) <> ''),
    time_zone varchar(100) NOT NULL DEFAULT 'Asia/Manila'
        CHECK (time_zone = 'UTC' OR time_zone ~ '^[A-Za-z_+-]+(/[A-Za-z0-9_+-]+)+$'),
    active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    created_by_user_id uuid REFERENCES users (id),
    updated_by_user_id uuid REFERENCES users (id),
    UNIQUE (clinic_id, id),
    UNIQUE (clinic_id, code),
    CHECK (updated_at >= created_at)
);

CREATE FUNCTION validate_branch_time_zone() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name = NEW.time_zone) THEN
        RAISE EXCEPTION 'Unknown branch time zone: %', NEW.time_zone USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER branches_validate_time_zone
    BEFORE INSERT OR UPDATE OF time_zone ON branches
    FOR EACH ROW EXECUTE FUNCTION validate_branch_time_zone();

CREATE TABLE staff_memberships (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    clinic_id uuid NOT NULL REFERENCES clinics (id),
    user_id uuid NOT NULL REFERENCES users (id),
    status varchar(16) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'REVOKED')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    created_by_user_id uuid REFERENCES users (id),
    updated_by_user_id uuid REFERENCES users (id),
    UNIQUE (clinic_id, id),
    UNIQUE (clinic_id, user_id),
    CHECK (updated_at >= created_at)
);

CREATE TABLE membership_roles (
    clinic_id uuid NOT NULL,
    membership_id uuid NOT NULL,
    role varchar(20) NOT NULL CHECK (role IN ('CLINIC_ADMIN', 'RECEPTIONIST', 'DOCTOR')),
    PRIMARY KEY (membership_id, role),
    FOREIGN KEY (clinic_id, membership_id) REFERENCES staff_memberships (clinic_id, id)
);

CREATE TABLE membership_branches (
    clinic_id uuid NOT NULL,
    membership_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    PRIMARY KEY (clinic_id, membership_id, branch_id),
    FOREIGN KEY (clinic_id, membership_id) REFERENCES staff_memberships (clinic_id, id),
    FOREIGN KEY (clinic_id, branch_id) REFERENCES branches (clinic_id, id)
);

CREATE TABLE providers (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    clinic_id uuid NOT NULL REFERENCES clinics (id),
    staff_membership_id uuid,
    display_name varchar(160) NOT NULL CHECK (btrim(display_name) <> ''),
    active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    created_by_user_id uuid REFERENCES users (id),
    updated_by_user_id uuid REFERENCES users (id),
    UNIQUE (clinic_id, id),
    UNIQUE (clinic_id, staff_membership_id),
    FOREIGN KEY (clinic_id, staff_membership_id) REFERENCES staff_memberships (clinic_id, id),
    CHECK (updated_at >= created_at)
);

CREATE TABLE provider_branches (
    clinic_id uuid NOT NULL,
    provider_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    active boolean NOT NULL DEFAULT true,
    PRIMARY KEY (clinic_id, provider_id, branch_id),
    FOREIGN KEY (clinic_id, provider_id) REFERENCES providers (clinic_id, id),
    FOREIGN KEY (clinic_id, branch_id) REFERENCES branches (clinic_id, id)
);
CREATE INDEX provider_branches_directory_idx ON provider_branches (clinic_id, branch_id, provider_id)
    WHERE active;

CREATE TABLE patient_profiles (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    clinic_id uuid NOT NULL REFERENCES clinics (id),
    user_id uuid REFERENCES users (id),
    display_name varchar(160) NOT NULL CHECK (btrim(display_name) <> ''),
    contact_email varchar(320)
        CHECK (contact_email = lower(btrim(contact_email))
               AND contact_email ~ '^[^[:space:]@]+@[^[:space:]@]+$'),
    contact_phone varchar(32) CHECK (btrim(contact_phone) <> ''),
    archived_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    created_by_user_id uuid REFERENCES users (id),
    updated_by_user_id uuid REFERENCES users (id),
    UNIQUE (clinic_id, id),
    CHECK (updated_at >= created_at),
    CHECK (archived_at IS NULL OR archived_at >= created_at)
);
CREATE UNIQUE INDEX patient_profiles_linked_user
    ON patient_profiles (clinic_id, user_id) WHERE user_id IS NOT NULL;

CREATE TABLE staff_invitations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    clinic_id uuid NOT NULL REFERENCES clinics (id),
    email_normalized varchar(320) NOT NULL
        CHECK (email_normalized = lower(btrim(email_normalized))
               AND email_normalized ~ '^[^[:space:]@]+@[^[:space:]@]+$'),
    token_hash bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),
    roles text[] NOT NULL CHECK (
        array_ndims(roles) = 1 AND cardinality(roles) > 0
        AND array_position(roles, NULL) IS NULL
        AND roles <@ ARRAY['CLINIC_ADMIN', 'RECEPTIONIST', 'DOCTOR']::text[]
    ),
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    accepted_at timestamptz,
    revoked_at timestamptz,
    created_by_user_id uuid REFERENCES users (id),
    UNIQUE (clinic_id, id),
    CHECK (expires_at > created_at),
    CHECK (accepted_at IS NULL OR accepted_at >= created_at AND accepted_at < expires_at),
    CHECK (revoked_at IS NULL OR revoked_at >= created_at),
    CHECK (num_nonnulls(accepted_at, revoked_at) <= 1)
);
CREATE INDEX staff_invitations_clinic_email_idx ON staff_invitations (clinic_id, email_normalized, created_at DESC);

CREATE TABLE staff_invitation_branches (
    clinic_id uuid NOT NULL,
    invitation_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    PRIMARY KEY (clinic_id, invitation_id, branch_id),
    FOREIGN KEY (clinic_id, invitation_id) REFERENCES staff_invitations (clinic_id, id),
    FOREIGN KEY (clinic_id, branch_id) REFERENCES branches (clinic_id, id)
);

-- Offerings and schedules

CREATE TABLE services (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    clinic_id uuid NOT NULL REFERENCES clinics (id),
    name varchar(160) NOT NULL CHECK (btrim(name) <> ''),
    public_description varchar(800),
    duration_minutes smallint NOT NULL CHECK (duration_minutes BETWEEN 5 AND 480),
    active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    created_by_user_id uuid REFERENCES users (id),
    updated_by_user_id uuid REFERENCES users (id),
    UNIQUE (clinic_id, id),
    UNIQUE (clinic_id, name),
    CHECK (updated_at >= created_at)
);

CREATE TABLE provider_services (
    clinic_id uuid NOT NULL,
    provider_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    service_id uuid NOT NULL,
    active boolean NOT NULL DEFAULT true,
    PRIMARY KEY (clinic_id, provider_id, branch_id, service_id),
    FOREIGN KEY (clinic_id, provider_id, branch_id) REFERENCES provider_branches (clinic_id, provider_id, branch_id),
    FOREIGN KEY (clinic_id, service_id) REFERENCES services (clinic_id, id)
);
CREATE INDEX provider_services_directory_idx
    ON provider_services (clinic_id, branch_id, service_id, provider_id) WHERE active;

CREATE TABLE working_hours (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    clinic_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    provider_id uuid NOT NULL,
    day_of_week smallint NOT NULL CHECK (day_of_week BETWEEN 1 AND 7),
    local_start time NOT NULL,
    local_end time NOT NULL,
    effective_from date NOT NULL,
    effective_to date,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    created_by_user_id uuid REFERENCES users (id),
    updated_by_user_id uuid REFERENCES users (id),
    FOREIGN KEY (clinic_id, provider_id, branch_id) REFERENCES provider_branches (clinic_id, provider_id, branch_id),
    CHECK (local_end > local_start),
    CHECK (effective_to IS NULL OR effective_to >= effective_from),
    CHECK (updated_at >= created_at),
    -- ISO weekdays. effective_to is inclusive. Cross-branch comparisons need
    -- branch time zones and are validated by the schedule service.
    CONSTRAINT working_hours_no_overlap EXCLUDE USING gist (
        clinic_id WITH =, branch_id WITH =, provider_id WITH =, day_of_week WITH =,
        daterange(effective_from, effective_to, '[]') WITH &&,
        tsrange(DATE '2000-01-01' + local_start, DATE '2000-01-01' + local_end, '[)') WITH &&
    )
);

CREATE TABLE schedule_closures (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    clinic_id uuid NOT NULL REFERENCES clinics (id),
    branch_id uuid,
    provider_id uuid,
    starts_at timestamptz NOT NULL,
    ends_at timestamptz NOT NULL,
    reason_code varchar(48) NOT NULL CHECK (reason_code ~ '^[A-Z][A-Z0-9_]*$'),
    created_by uuid NOT NULL REFERENCES users (id),
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (clinic_id, branch_id) REFERENCES branches (clinic_id, id),
    FOREIGN KEY (clinic_id, provider_id) REFERENCES providers (clinic_id, id),
    FOREIGN KEY (clinic_id, provider_id, branch_id) REFERENCES provider_branches (clinic_id, provider_id, branch_id),
    CHECK (ends_at > starts_at)
);
CREATE INDEX schedule_closures_lookup_idx
    ON schedule_closures USING gist (clinic_id, tstzrange(starts_at, ends_at, '[)'));

-- Bookings and their history

CREATE TABLE appointments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    clinic_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    provider_id uuid NOT NULL,
    patient_profile_id uuid NOT NULL,
    service_id uuid NOT NULL,
    public_reference varchar(32) NOT NULL UNIQUE CHECK (public_reference ~ '^[A-Z0-9-]+$'),
    starts_at timestamptz NOT NULL,
    ends_at timestamptz NOT NULL,
    status varchar(20) NOT NULL DEFAULT 'CONFIRMED'
        CHECK (status IN ('CONFIRMED', 'CHECKED_IN', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED', 'NO_SHOW')),
    source varchar(12) NOT NULL CHECK (source IN ('PATIENT', 'STAFF', 'WALK_IN')),
    row_version bigint NOT NULL DEFAULT 0 CHECK (row_version >= 0),
    schedule_revision integer NOT NULL DEFAULT 1 CHECK (schedule_revision >= 1),
    policy_snapshot_json jsonb NOT NULL CHECK (jsonb_typeof(policy_snapshot_json) = 'object'),
    service_name_snapshot varchar(160) NOT NULL CHECK (btrim(service_name_snapshot) <> ''),
    duration_minutes_snapshot smallint NOT NULL CHECK (duration_minutes_snapshot BETWEEN 5 AND 480),
    created_by_user_id uuid REFERENCES users (id),
    cancelled_at timestamptz,
    cancelled_by_user_id uuid REFERENCES users (id),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (clinic_id, id),
    FOREIGN KEY (clinic_id, provider_id, branch_id, service_id)
        REFERENCES provider_services (clinic_id, provider_id, branch_id, service_id),
    FOREIGN KEY (clinic_id, patient_profile_id) REFERENCES patient_profiles (clinic_id, id),
    CHECK (ends_at > starts_at),
    CHECK (extract(epoch FROM ends_at - starts_at) = duration_minutes_snapshot * 60),
    CHECK ((status = 'CANCELLED') = (cancelled_at IS NOT NULL)),
    CHECK (cancelled_by_user_id IS NULL OR cancelled_at IS NOT NULL),
    CHECK (cancelled_at IS NULL OR cancelled_at BETWEEN created_at AND updated_at),
    CHECK (updated_at >= created_at),
    CONSTRAINT appointments_provider_no_overlap EXCLUDE USING gist (
        clinic_id WITH =, provider_id WITH =, tstzrange(starts_at, ends_at, '[)') WITH &&
    ) WHERE (status <> 'CANCELLED')
);
CREATE INDEX appointments_branch_calendar_idx ON appointments (clinic_id, branch_id, starts_at, id);
CREATE INDEX appointments_provider_agenda_idx ON appointments (clinic_id, provider_id, starts_at, id);
CREATE INDEX appointments_patient_history_idx ON appointments (clinic_id, patient_profile_id, starts_at DESC, id);

CREATE TABLE appointment_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    clinic_id uuid NOT NULL,
    appointment_id uuid NOT NULL,
    actor_user_id uuid REFERENCES users (id),
    event_type varchar(20) NOT NULL
        CHECK (event_type IN ('BOOKED', 'RESCHEDULED', 'CHECKED_IN', 'STARTED', 'COMPLETED', 'CANCELLED', 'NO_SHOW')),
    before_json jsonb,
    after_json jsonb NOT NULL,
    reason_code varchar(48) CHECK (reason_code ~ '^[A-Z][A-Z0-9_]*$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (clinic_id, appointment_id) REFERENCES appointments (clinic_id, id),
    CHECK (before_json IS NULL OR jsonb_typeof(before_json) = 'object'),
    CHECK (jsonb_typeof(after_json) = 'object'),
    CHECK (before_json - ARRAY['status', 'startsAt', 'endsAt', 'branchId', 'providerId', 'scheduleRevision'] = '{}'::jsonb),
    CHECK (after_json - ARRAY['status', 'startsAt', 'endsAt', 'branchId', 'providerId', 'scheduleRevision'] = '{}'::jsonb),
    CHECK ((event_type = 'BOOKED') = (before_json IS NULL))
);
CREATE INDEX appointment_events_history_idx ON appointment_events (clinic_id, appointment_id, created_at, id);

CREATE TABLE idempotency_keys (
    clinic_id uuid NOT NULL REFERENCES clinics (id),
    actor_user_id uuid NOT NULL REFERENCES users (id),
    operation varchar(24) NOT NULL CHECK (operation IN ('BOOK', 'RESCHEDULE', 'CANCEL')),
    request_key varchar(128) NOT NULL CHECK (btrim(request_key) <> ''),
    request_hash bytea NOT NULL CHECK (octet_length(request_hash) = 32),
    resource_id uuid,
    response_status smallint CHECK (response_status BETWEEN 200 AND 599),
    response_json jsonb CHECK (jsonb_typeof(response_json) = 'object'),
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    PRIMARY KEY (clinic_id, actor_user_id, operation, request_key),
    FOREIGN KEY (clinic_id, resource_id) REFERENCES appointments (clinic_id, id),
    CHECK (response_json IS NULL OR response_status IS NOT NULL),
    CHECK (expires_at > created_at)
);
CREATE INDEX idempotency_keys_expires_idx ON idempotency_keys (expires_at);

-- Notifications, reporting, and security audit

CREATE TABLE notification_outbox (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    clinic_id uuid NOT NULL,
    appointment_id uuid NOT NULL,
    schedule_revision integer NOT NULL CHECK (schedule_revision >= 1),
    kind varchar(24) NOT NULL
        CHECK (kind IN ('CONFIRMATION', 'RESCHEDULED', 'CANCELLED', 'REMINDER_24H', 'REMINDER_2H')),
    channel varchar(12) NOT NULL DEFAULT 'EMAIL' CHECK (channel = 'EMAIL'),
    scheduled_for timestamptz NOT NULL,
    available_at timestamptz NOT NULL,
    state varchar(16) NOT NULL DEFAULT 'QUEUED'
        CHECK (state IN ('QUEUED', 'RUNNING', 'SENT', 'FAILED', 'SUPERSEDED')),
    attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    lease_token uuid,
    lease_expires_at timestamptz,
    provider_message_ref varchar(180),
    sent_at timestamptz,
    failure_code varchar(48) CHECK (failure_code ~ '^[A-Z][A-Z0-9_]*$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (clinic_id, appointment_id) REFERENCES appointments (clinic_id, id),
    UNIQUE (appointment_id, schedule_revision, kind, channel),
    CHECK (available_at >= scheduled_for),
    CHECK ((lease_token IS NULL) = (lease_expires_at IS NULL)),
    CHECK ((state = 'RUNNING') = (lease_token IS NOT NULL)),
    CHECK ((state = 'SENT') = (sent_at IS NOT NULL)),
    CHECK (state <> 'FAILED' OR failure_code IS NOT NULL),
    CHECK (sent_at IS NULL OR sent_at >= scheduled_for)
);
CREATE INDEX notification_outbox_due_idx ON notification_outbox (available_at, id) WHERE state = 'QUEUED';
CREATE INDEX notification_outbox_expired_lease_idx
    ON notification_outbox (lease_expires_at, id) WHERE state = 'RUNNING';

CREATE TABLE daily_branch_metrics (
    clinic_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    business_date date NOT NULL,
    confirmed_count integer NOT NULL DEFAULT 0 CHECK (confirmed_count >= 0),
    completed_count integer NOT NULL DEFAULT 0 CHECK (completed_count >= 0),
    cancelled_count integer NOT NULL DEFAULT 0 CHECK (cancelled_count >= 0),
    no_show_count integer NOT NULL DEFAULT 0 CHECK (no_show_count >= 0),
    generated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (clinic_id, branch_id, business_date),
    FOREIGN KEY (clinic_id, branch_id) REFERENCES branches (clinic_id, id)
);

CREATE TABLE report_exports (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    clinic_id uuid NOT NULL,
    requested_by uuid NOT NULL,
    report_type varchar(24) NOT NULL CHECK (report_type = 'DAILY_BRANCH_METRICS'),
    filters_json jsonb NOT NULL CHECK (jsonb_typeof(filters_json) = 'object'),
    state varchar(16) NOT NULL DEFAULT 'QUEUED'
        CHECK (state IN ('QUEUED', 'RUNNING', 'READY', 'FAILED', 'EXPIRED')),
    object_key varchar(500),
    expires_at timestamptz,
    error_code varchar(48) CHECK (error_code ~ '^[A-Z][A-Z0-9_]*$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (clinic_id, requested_by) REFERENCES staff_memberships (clinic_id, user_id),
    CHECK (state <> 'READY' OR (object_key IS NOT NULL AND expires_at IS NOT NULL)),
    CHECK (state <> 'FAILED' OR error_code IS NOT NULL),
    CHECK (expires_at IS NULL OR expires_at > created_at)
);
CREATE INDEX report_exports_clinic_history_idx ON report_exports (clinic_id, requested_by, created_at DESC);
CREATE INDEX report_exports_expires_idx ON report_exports (expires_at) WHERE expires_at IS NOT NULL;

CREATE TABLE audit_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    clinic_id uuid NOT NULL REFERENCES clinics (id),
    actor_user_id uuid REFERENCES users (id),
    action varchar(48) NOT NULL CHECK (action ~ '^[A-Z][A-Z0-9_]*$'),
    resource_type varchar(48) NOT NULL CHECK (resource_type ~ '^[A-Z][A-Z0-9_]*$'),
    resource_id uuid NOT NULL,
    request_id uuid,
    details_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(details_json) = 'object'),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_events_clinic_time_idx ON audit_events (clinic_id, created_at DESC, id);

CREATE FUNCTION reject_history_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% is append-only', TG_TABLE_NAME USING ERRCODE = '23514';
END;
$$;

CREATE TRIGGER appointment_events_append_only
    BEFORE UPDATE OR DELETE ON appointment_events
    FOR EACH ROW EXECUTE FUNCTION reject_history_change();
CREATE TRIGGER audit_events_append_only
    BEFORE UPDATE OR DELETE ON audit_events
    FOR EACH ROW EXECUTE FUNCTION reject_history_change();

-- DEVELOPMENT SEED. Remove everything from this marker through the line before
-- COMMIT for schema-only setup. Seed dates are relative to the Manila calendar.
-- Seed hashes are fixtures. Configure demo sign-in through your application.

CREATE TEMP VIEW demo_clock AS
SELECT (now() AT TIME ZONE 'Asia/Manila')::date AS today, now() AS loaded_at;

CREATE TEMP TABLE demo_clinics ON COMMIT DROP AS
SELECT n AS clinic_no, gen_random_uuid() AS clinic_id,
       CASE n WHEN 1 THEN 'demo-harbor-clinic' ELSE 'demo-garden-clinic' END AS slug
FROM generate_series(1, 2) AS g(n);

CREATE TEMP TABLE demo_staff ON COMMIT DROP AS
SELECT c.*, n AS staff_no, gen_random_uuid() AS user_id, gen_random_uuid() AS membership_id,
       CASE WHEN n = 1 THEN 'CLINIC_ADMIN' WHEN n <= 4 OR n = 11 THEN 'RECEPTIONIST' ELSE 'DOCTOR' END AS role
FROM demo_clinics c CROSS JOIN generate_series(1, 11) AS g(n);

CREATE TEMP TABLE demo_patients ON COMMIT DROP AS
SELECT c.clinic_no, c.clinic_id, n AS patient_no, gen_random_uuid() AS profile_id,
       CASE WHEN n <= 60 THEN gen_random_uuid() END AS user_id
FROM demo_clinics c CROSS JOIN generate_series(1, 72) AS g(n);

INSERT INTO users (id, email_normalized, display_name, email_verified_at, status, created_at, updated_at)
SELECT s.user_id, format('staff%s@%s.test', s.staff_no, s.slug),
       format('Demo %s %s-%s', initcap(replace(s.role, '_', ' ')), s.clinic_no, s.staff_no),
       k.loaded_at - interval '59 days', CASE WHEN s.staff_no = 11 THEN 'DISABLED' ELSE 'ACTIVE' END,
       k.loaded_at - interval '60 days', k.loaded_at
FROM demo_staff s CROSS JOIN demo_clock k
UNION ALL
SELECT p.user_id, format('patient%s@%s.test', p.patient_no, c.slug),
       format('Demo Patient %s-%s', p.clinic_no, p.patient_no),
       k.loaded_at - interval '59 days', 'ACTIVE',
       k.loaded_at - interval '60 days', k.loaded_at
FROM demo_patients p JOIN demo_clinics c USING (clinic_id) CROSS JOIN demo_clock k
WHERE p.user_id IS NOT NULL;

INSERT INTO clinics (id, slug, display_name, status, booking_horizon_days, created_by_user_id, updated_by_user_id)
SELECT c.clinic_id, c.slug,
       CASE c.clinic_no WHEN 1 THEN 'Harbor Demo Clinic' ELSE 'Garden Demo Clinic' END,
       'PUBLISHED', 45, s.user_id, s.user_id
FROM demo_clinics c JOIN demo_staff s ON s.clinic_id = c.clinic_id AND s.staff_no = 1;

CREATE TEMP TABLE demo_branches ON COMMIT DROP AS
SELECT c.clinic_no, c.clinic_id, n AS branch_no, gen_random_uuid() AS branch_id
FROM demo_clinics c CROSS JOIN generate_series(1, 3) AS g(n);

INSERT INTO branches (id, clinic_id, code, name, address_display, created_by_user_id, updated_by_user_id)
SELECT b.branch_id, b.clinic_id, (ARRAY['CENTRAL', 'NORTH', 'SOUTH'])[b.branch_no],
       (ARRAY['Central Branch', 'North Branch', 'South Branch'])[b.branch_no],
       format('Demo site %s-%s, Cebu, Philippines', b.clinic_no, b.branch_no), s.user_id, s.user_id
FROM demo_branches b JOIN demo_staff s ON s.clinic_id = b.clinic_id AND s.staff_no = 1;

INSERT INTO staff_memberships (id, clinic_id, user_id, status, created_by_user_id, updated_by_user_id)
SELECT s.membership_id, s.clinic_id, s.user_id,
       CASE WHEN s.staff_no = 11 THEN 'REVOKED' ELSE 'ACTIVE' END, a.user_id, a.user_id
FROM demo_staff s JOIN demo_staff a ON a.clinic_id = s.clinic_id AND a.staff_no = 1;

INSERT INTO staff_credentials (user_id, password_hash)
SELECT user_id, '{bcrypt}$2b$12$Tsm5LgQ.KPlPDZ0afj5qL.XV16IBNz9.7.WbwhkeiX1v7FKyNZWWK'
FROM demo_staff;

INSERT INTO membership_roles (clinic_id, membership_id, role)
SELECT clinic_id, membership_id, role FROM demo_staff
UNION ALL
SELECT clinic_id, membership_id, 'RECEPTIONIST' FROM demo_staff WHERE staff_no = 1;

INSERT INTO membership_branches (clinic_id, membership_id, branch_id)
SELECT s.clinic_id, s.membership_id, b.branch_id
FROM demo_staff s JOIN demo_branches b USING (clinic_id)
WHERE (s.staff_no BETWEEN 2 AND 4 AND b.branch_no = s.staff_no - 1)
   OR (s.staff_no BETWEEN 5 AND 10 AND b.branch_no = (s.staff_no - 5) / 2 + 1)
   OR (s.staff_no = 5 AND b.branch_no = 2);

INSERT INTO patient_profiles (id, clinic_id, user_id, display_name, contact_email, archived_at, created_at, updated_at)
SELECT p.profile_id, p.clinic_id, p.user_id,
       format('Demo Patient %s-%s', p.clinic_no, p.patient_no),
       format('patient%s@%s.test', p.patient_no, c.slug),
       CASE WHEN p.patient_no = 72 THEN k.loaded_at - interval '1 day' END,
       k.loaded_at - interval '59 days', k.loaded_at
FROM demo_patients p JOIN demo_clinics c USING (clinic_id) CROSS JOIN demo_clock k;

CREATE TEMP TABLE demo_providers ON COMMIT DROP AS
SELECT s.clinic_id, s.staff_no - 4 AS provider_no, gen_random_uuid() AS provider_id,
       s.membership_id, s.user_id
FROM demo_staff s WHERE s.staff_no BETWEEN 5 AND 10
UNION ALL
SELECT clinic_id, 7, gen_random_uuid(), NULL, NULL FROM demo_clinics;

INSERT INTO providers (id, clinic_id, staff_membership_id, display_name, active)
SELECT provider_id, clinic_id, membership_id, format('Dr. Demo Provider %s', provider_no), provider_no <> 7
FROM demo_providers;

INSERT INTO provider_branches (clinic_id, provider_id, branch_id, active)
SELECT p.clinic_id, p.provider_id, b.branch_id, p.provider_no <> 7
FROM demo_providers p JOIN demo_branches b USING (clinic_id)
WHERE b.branch_no = least((p.provider_no - 1) / 2 + 1, 3)
   OR (p.provider_no = 1 AND b.branch_no = 2);

CREATE TEMP TABLE demo_services ON COMMIT DROP AS
SELECT clinic_id, n AS service_no, gen_random_uuid() AS service_id, name, duration
FROM demo_clinics
CROSS JOIN (VALUES (1, 'General Consultation', 30), (2, 'Follow-up Visit', 15),
                   (3, 'Extended Consultation', 45), (4, 'Wellness Check', 30),
                   (5, 'Archived Offering', 15)) AS s(n, name, duration);

INSERT INTO services (id, clinic_id, name, public_description, duration_minutes, active)
SELECT service_id, clinic_id, name, 'Fictional service for local development.', duration, service_no <> 5
FROM demo_services;

INSERT INTO provider_services (clinic_id, provider_id, branch_id, service_id, active)
SELECT pb.clinic_id, pb.provider_id, pb.branch_id, s.service_id, pb.active AND s.service_no <> 5
FROM provider_branches pb JOIN demo_services s USING (clinic_id);

INSERT INTO working_hours (clinic_id, branch_id, provider_id, day_of_week, local_start, local_end, effective_from)
SELECT pb.clinic_id, pb.branch_id, pb.provider_id, wd.n, w.start_time, w.end_time, k.today - 90
FROM provider_branches pb JOIN demo_providers p USING (clinic_id, provider_id)
JOIN demo_branches b USING (clinic_id, branch_id)
CROSS JOIN generate_series(1, 6) AS wd(n)
CROSS JOIN (VALUES (time '08:00', time '12:00'), (time '13:00', time '17:00')) AS w(start_time, end_time)
CROSS JOIN demo_clock k
WHERE pb.active
  AND CASE WHEN p.provider_no = 1 AND b.branch_no = 2 THEN wd.n = 6
           WHEN p.provider_no = 1 THEN wd.n <= 5 ELSE true END;

INSERT INTO schedule_closures (clinic_id, branch_id, provider_id, starts_at, ends_at, reason_code, created_by)
SELECT c.clinic_id, CASE WHEN x.scope IN (2, 4) THEN b.branch_id END,
       CASE WHEN x.scope IN (3, 4) THEN p.provider_id END,
       ((k.today + x.day_offset) + x.start_time) AT TIME ZONE 'Asia/Manila',
       ((k.today + x.day_offset) + x.end_time) AT TIME ZONE 'Asia/Manila',
       x.reason, s.user_id
FROM demo_clinics c
JOIN demo_staff s ON s.clinic_id = c.clinic_id AND s.staff_no = 1
JOIN demo_branches b ON b.clinic_id = c.clinic_id AND b.branch_no = 2
JOIN demo_providers p ON p.clinic_id = c.clinic_id AND p.provider_no = 3
CROSS JOIN demo_clock k
CROSS JOIN (VALUES (1, 7, time '00:00', time '24:00', 'CLINIC_HOLIDAY'),
                   (2, 9, time '08:00', time '17:00', 'BRANCH_MAINTENANCE'),
                   (3, 5, time '13:00', time '17:00', 'PROVIDER_LEAVE'),
                   (4, -3, time '08:00', time '12:00', 'PROVIDER_TRAINING'))
            AS x(scope, day_offset, start_time, end_time, reason);

-- Completed, superseded, expired, and open challenges. The byte strings are
-- fixture digests for tests of listings and retention.
INSERT INTO auth_challenges
    (destination_normalized, purpose, secret_digest, created_at, expires_at, failed_attempts, consumed_at, superseded_at)
SELECT u.email_normalized, CASE WHEN u.email_normalized LIKE 'staff%' THEN 'STAFF_RECOVERY' ELSE 'PATIENT_SIGN_IN' END,
       sha256(convert_to(u.email_normalized || ':demo-challenge:' || n, 'UTF8')),
       k.loaded_at - make_interval(mins => (ARRAY[40, 25, 12, 2])[n]),
       k.loaded_at - make_interval(mins => (ARRAY[30, 15, 2, -8])[n]),
       n - 1, CASE WHEN n = 1 THEN k.loaded_at - interval '38 minutes' END,
       CASE WHEN n IN (2, 3) THEN k.loaded_at - make_interval(mins => (ARRAY[0, 12, 2])[n]) END
FROM users u CROSS JOIN demo_clock k CROSS JOIN generate_series(1, 4) AS g(n)
WHERE u.email_normalized ~ '^(staff[12]|patient[1-8])@';

INSERT INTO staff_invitations (clinic_id, email_normalized, token_hash, roles, created_at,
                               expires_at, accepted_at, revoked_at, created_by_user_id)
SELECT c.clinic_id, format('invite%s@%s.test', n, c.slug),
       sha256(convert_to(c.slug || ':demo-invite:' || n, 'UTF8')),
       CASE WHEN n = 1 THEN ARRAY['DOCTOR'] ELSE ARRAY['RECEPTIONIST'] END,
       k.loaded_at - make_interval(days => CASE WHEN n = 4 THEN 10 ELSE 2 END),
       k.loaded_at + make_interval(days => CASE WHEN n = 4 THEN -3 ELSE 5 END),
       CASE WHEN n = 2 THEN k.loaded_at - interval '1 day' END,
       CASE WHEN n = 3 THEN k.loaded_at - interval '1 day' END, s.user_id
FROM demo_clinics c JOIN demo_staff s ON s.clinic_id = c.clinic_id AND s.staff_no = 1
CROSS JOIN demo_clock k CROSS JOIN generate_series(1, 4) AS g(n);

INSERT INTO staff_invitation_branches (clinic_id, invitation_id, branch_id)
SELECT i.clinic_id, i.id, b.branch_id
FROM staff_invitations i JOIN demo_branches b USING (clinic_id)
WHERE b.branch_no IN (1, 2);

-- Four candidate bookings per provider/day. Split working windows, closures,
-- alternate branches, and appointment durations all affect the seed calendar.
CREATE TEMP TABLE demo_bookings ON COMMIT DROP AS
WITH candidate AS (
    SELECT w.clinic_id, b.clinic_no, b.branch_no, w.branch_id, p.provider_no, w.provider_id,
           d.local_date, x.slot_no, s.service_id, s.name, s.duration,
           t.starts_at, t.starts_at + make_interval(mins => s.duration) AS ends_at,
           k.today, k.loaded_at
    FROM working_hours w
    JOIN demo_branches b USING (clinic_id, branch_id)
    JOIN demo_providers p USING (clinic_id, provider_id)
    CROSS JOIN demo_clock k
    CROSS JOIN generate_series(-21, 14) AS g(day_offset)
    CROSS JOIN LATERAL (SELECT k.today + g.day_offset AS local_date) AS d
    CROSS JOIN (VALUES (1, time '09:00'), (2, time '10:00'),
                       (3, time '13:30'), (4, time '15:00')) AS x(slot_no, local_start)
    JOIN demo_services s ON s.clinic_id = w.clinic_id AND s.service_no = (x.slot_no + p.provider_no) % 4 + 1
    CROSS JOIN LATERAL (SELECT (d.local_date + x.local_start) AT TIME ZONE 'Asia/Manila' AS starts_at) AS t
    WHERE w.day_of_week = extract(isodow FROM d.local_date)
      AND x.local_start >= w.local_start
      AND x.local_start + make_interval(mins => s.duration) <= w.local_end
      AND NOT EXISTS (
          SELECT 1 FROM schedule_closures cl
          WHERE cl.clinic_id = w.clinic_id
            AND (cl.branch_id IS NULL OR cl.branch_id = w.branch_id)
            AND (cl.provider_id IS NULL OR cl.provider_id = w.provider_id)
            AND tstzrange(cl.starts_at, cl.ends_at, '[)') &&
                tstzrange(t.starts_at, t.starts_at + make_interval(mins => s.duration), '[)')
      )
), numbered AS (
    SELECT candidate.*,
           row_number() OVER (PARTITION BY clinic_id ORDER BY starts_at, provider_no) AS serial_no
    FROM candidate
), scenarios AS (
    SELECT numbered.*,
           CASE WHEN local_date = today - CASE WHEN extract(isodow FROM today) = 1 THEN 2 ELSE 1 END
                     AND provider_no = 2 AND slot_no = 3 THEN 'CHECKED_IN'
                WHEN local_date = today - CASE WHEN extract(isodow FROM today) = 1 THEN 2 ELSE 1 END
                     AND provider_no = 2 AND slot_no = 4 THEN 'IN_PROGRESS'
                WHEN serial_no % 11 = 0 THEN 'CANCELLED'
                WHEN local_date < today AND serial_no % 8 = 0 THEN 'NO_SHOW'
                WHEN local_date < today THEN 'COMPLETED'
                WHEN local_date = today AND starts_at <= loaded_at AND slot_no = 1 THEN 'IN_PROGRESS'
                WHEN local_date = today AND starts_at <= loaded_at AND slot_no = 2 THEN 'CHECKED_IN'
                ELSE 'CONFIRMED' END AS status,
           CASE WHEN serial_no % 13 = 0 AND starts_at <= loaded_at THEN 'WALK_IN'
                WHEN serial_no % 5 = 0 OR serial_no % 3 = 0 THEN 'STAFF' ELSE 'PATIENT' END AS source
    FROM numbered
), assigned AS (
    SELECT v.*, p.profile_id,
           staff.user_id AS staff_actor, provider.user_id AS provider_actor,
           CASE WHEN v.source = 'PATIENT' THEN p.user_id ELSE staff.user_id END AS booked_by,
           CASE WHEN v.source = 'WALK_IN' THEN least(v.starts_at, v.loaded_at) - interval '10 minutes'
                ELSE least(v.starts_at - interval '3 days', v.loaded_at - interval '6 hours') END AS booked_at,
           v.status = 'CONFIRMED' AND v.local_date >= v.today + 2 AND v.serial_no % 19 = 0 AS rescheduled
    FROM scenarios v
    JOIN demo_patients p ON p.clinic_id = v.clinic_id AND p.patient_no =
         CASE WHEN v.source = 'PATIENT' THEN (v.serial_no * 7) % 60 + 1
              ELSE (v.serial_no * 7) % 71 + 1 END
    JOIN demo_staff staff ON staff.clinic_id = v.clinic_id AND staff.staff_no = v.branch_no + 1
    JOIN demo_providers provider ON provider.clinic_id = v.clinic_id AND provider.provider_id = v.provider_id
)
SELECT a.*, gen_random_uuid() AS appointment_id,
       'DEMO-' || a.clinic_no || '-' || lpad(a.serial_no::text, 5, '0') AS reference,
       CASE WHEN a.status = 'CANCELLED' THEN
           least(a.loaded_at, CASE WHEN a.source = 'WALK_IN' THEN a.booked_at + interval '5 minutes'
                                   ELSE a.starts_at - interval '1 day' END) END AS cancelled_at
FROM assigned a;

INSERT INTO appointments
    (id, clinic_id, branch_id, provider_id, patient_profile_id, service_id, public_reference,
     starts_at, ends_at, status, source, row_version, schedule_revision, policy_snapshot_json,
     service_name_snapshot, duration_minutes_snapshot, created_by_user_id, cancelled_at,
     cancelled_by_user_id, created_at, updated_at)
SELECT v.appointment_id, v.clinic_id, v.branch_id, v.provider_id, v.profile_id, v.service_id, v.reference,
       v.starts_at, v.ends_at, v.status, v.source,
       CASE v.status WHEN 'COMPLETED' THEN 3 WHEN 'IN_PROGRESS' THEN 2
            WHEN 'CONFIRMED' THEN CASE WHEN v.rescheduled THEN 1 ELSE 0 END ELSE 1 END,
       CASE WHEN v.rescheduled OR v.status = 'CANCELLED' THEN 2 ELSE 1 END,
       jsonb_build_object('bookingHorizonDays', c.booking_horizon_days, 'slotStepMinutes', c.slot_step_minutes,
                          'minLeadMinutes', c.min_lead_minutes, 'patientChangeCutoffMinutes', c.patient_change_cutoff_minutes),
       v.name, v.duration, v.booked_by, v.cancelled_at,
       CASE WHEN v.cancelled_at IS NOT NULL THEN v.booked_by END, v.booked_at,
       CASE v.status WHEN 'COMPLETED' THEN v.ends_at WHEN 'NO_SHOW' THEN v.ends_at
            WHEN 'CANCELLED' THEN v.cancelled_at WHEN 'CHECKED_IN' THEN v.starts_at
            WHEN 'IN_PROGRESS' THEN v.starts_at ELSE CASE WHEN v.rescheduled THEN v.loaded_at - interval '2 hours'
                                                      ELSE v.booked_at END END
FROM demo_bookings v JOIN clinics c ON c.id = v.clinic_id;

-- Seed the full path for each state, plus reschedule examples with a new revision.
WITH snapshots AS (
    SELECT b.*,
           jsonb_build_object('status', 'CONFIRMED', 'startsAt', b.starts_at, 'endsAt', b.ends_at,
                              'branchId', b.branch_id, 'providerId', b.provider_id, 'scheduleRevision', 1) AS initial,
           jsonb_build_object('startsAt', b.starts_at - interval '15 minutes',
                              'endsAt', b.ends_at - interval '15 minutes') AS previous_times
    FROM demo_bookings b
)
INSERT INTO appointment_events
    (clinic_id, appointment_id, actor_user_id, event_type, before_json, after_json, reason_code, created_at)
SELECT clinic_id, appointment_id, booked_by, 'BOOKED', NULL,
       CASE WHEN rescheduled THEN initial || previous_times ELSE initial END, NULL, booked_at
FROM snapshots
UNION ALL
SELECT clinic_id, appointment_id, booked_by, 'RESCHEDULED', initial || previous_times,
       initial || '{"scheduleRevision": 2}', 'PATIENT_REQUEST', loaded_at - interval '2 hours'
FROM snapshots WHERE rescheduled
UNION ALL
SELECT clinic_id, appointment_id, staff_actor, 'CHECKED_IN', initial,
       initial || '{"status":"CHECKED_IN"}', NULL, starts_at - interval '5 minutes'
FROM snapshots WHERE status IN ('CHECKED_IN', 'IN_PROGRESS', 'COMPLETED')
UNION ALL
SELECT clinic_id, appointment_id, provider_actor, 'STARTED', initial || '{"status":"CHECKED_IN"}',
       initial || '{"status":"IN_PROGRESS"}', NULL, starts_at
FROM snapshots WHERE status IN ('IN_PROGRESS', 'COMPLETED')
UNION ALL
SELECT clinic_id, appointment_id, provider_actor, 'COMPLETED', initial || '{"status":"IN_PROGRESS"}',
       initial || '{"status":"COMPLETED"}', NULL, ends_at
FROM snapshots WHERE status = 'COMPLETED'
UNION ALL
SELECT clinic_id, appointment_id, booked_by, 'CANCELLED', initial,
       initial || '{"status":"CANCELLED","scheduleRevision":2}', 'PATIENT_REQUEST', cancelled_at
FROM snapshots WHERE status = 'CANCELLED'
UNION ALL
SELECT clinic_id, appointment_id, staff_actor, 'NO_SHOW', initial,
       initial || '{"status":"NO_SHOW"}', 'GRACE_PERIOD_ELAPSED', ends_at
FROM snapshots WHERE status = 'NO_SHOW';

INSERT INTO idempotency_keys
    (clinic_id, actor_user_id, operation, request_key, request_hash, resource_id, response_status,
     response_json, created_at, expires_at)
SELECT clinic_id, booked_by, x.operation, lower(reference || '-' || x.operation),
       sha256(convert_to(reference || ':' || x.operation, 'UTF8')),
       appointment_id, CASE WHEN x.operation = 'BOOK' THEN 201 ELSE 200 END,
       jsonb_build_object('appointmentId', appointment_id, 'reference', reference,
                          'status', CASE WHEN x.operation = 'CANCEL' THEN 'CANCELLED' ELSE 'CONFIRMED' END,
                          'version', CASE WHEN x.operation = 'BOOK' THEN 0 ELSE 1 END),
       x.created_at, x.created_at + interval '72 hours'
FROM demo_bookings
CROSS JOIN LATERAL (
    VALUES ('BOOK', booked_at), ('RESCHEDULE', CASE WHEN rescheduled THEN loaded_at - interval '2 hours' END),
           ('CANCEL', cancelled_at)
) AS x(operation, created_at)
WHERE x.created_at IS NOT NULL AND (serial_no % 3 = 0 OR x.operation <> 'BOOK');

WITH messages AS (
    SELECT v.*, x.kind, x.schedule_revision, x.scheduled_for,
           CASE WHEN x.kind LIKE 'REMINDER%' AND (v.status = 'CANCELLED' OR v.rescheduled AND x.schedule_revision = 1)
                     THEN 'SUPERSEDED'
                WHEN x.scheduled_for > v.loaded_at THEN 'QUEUED'
                WHEN v.serial_no % 29 = 0 AND x.kind = 'CONFIRMATION' THEN 'FAILED'
                WHEN v.serial_no % 23 = 0 AND x.kind = 'CONFIRMATION' AND v.status = 'CONFIRMED' THEN 'RUNNING'
                WHEN v.serial_no % 17 = 0 AND x.kind = 'CONFIRMATION' AND v.status = 'CONFIRMED' THEN 'QUEUED'
                ELSE 'SENT' END AS delivery_state
    FROM demo_bookings v
    CROSS JOIN LATERAL (
        VALUES ('CONFIRMATION', 1, v.booked_at),
               ('REMINDER_24H', 1, v.starts_at - interval '24 hours' - CASE WHEN v.rescheduled THEN interval '15 minutes' ELSE interval '0' END),
               ('REMINDER_2H', 1, v.starts_at - interval '2 hours' - CASE WHEN v.rescheduled THEN interval '15 minutes' ELSE interval '0' END),
               ('RESCHEDULED', 2, CASE WHEN v.rescheduled THEN v.loaded_at - interval '2 hours' END),
               ('REMINDER_24H', 2, CASE WHEN v.rescheduled THEN v.starts_at - interval '24 hours' END),
               ('REMINDER_2H', 2, CASE WHEN v.rescheduled THEN v.starts_at - interval '2 hours' END),
               ('CANCELLED', 2, v.cancelled_at)
    ) AS x(kind, schedule_revision, scheduled_for)
    WHERE x.scheduled_for IS NOT NULL AND x.scheduled_for >= v.booked_at
)
INSERT INTO notification_outbox
    (clinic_id, appointment_id, schedule_revision, kind, scheduled_for, available_at, state,
     attempt_count, lease_token, lease_expires_at, provider_message_ref, sent_at, failure_code, created_at)
SELECT clinic_id, appointment_id, schedule_revision, kind, scheduled_for,
       CASE WHEN delivery_state = 'QUEUED' AND scheduled_for <= loaded_at THEN greatest(scheduled_for, loaded_at - interval '1 minute')
            ELSE scheduled_for END,
       delivery_state, CASE WHEN delivery_state = 'FAILED' THEN 3
                            WHEN delivery_state IN ('RUNNING', 'SENT') THEN 1
                            WHEN delivery_state = 'QUEUED' AND scheduled_for <= loaded_at THEN 1 ELSE 0 END,
       CASE WHEN delivery_state = 'RUNNING' THEN gen_random_uuid() END,
       CASE WHEN delivery_state = 'RUNNING' THEN loaded_at - interval '1 minute' END,
       CASE WHEN delivery_state = 'SENT' THEN concat(reference, '-', kind, '-', schedule_revision) END,
       CASE WHEN delivery_state = 'SENT' THEN least(loaded_at, scheduled_for + interval '10 seconds') END,
       CASE WHEN delivery_state = 'FAILED' THEN 'DEMO_MAIL_TIMEOUT' END, booked_at
FROM messages;

INSERT INTO daily_branch_metrics
    (clinic_id, branch_id, business_date, confirmed_count, completed_count, cancelled_count, no_show_count)
SELECT b.clinic_id, b.id, k.today + g.day_offset,
       count(a.id) FILTER (WHERE a.status = 'CONFIRMED'),
       count(a.id) FILTER (WHERE a.status = 'COMPLETED'),
       count(a.id) FILTER (WHERE a.status = 'CANCELLED'),
       count(a.id) FILTER (WHERE a.status = 'NO_SHOW')
FROM branches b CROSS JOIN demo_clock k CROSS JOIN generate_series(-21, 0) AS g(day_offset)
LEFT JOIN appointments a ON a.clinic_id = b.clinic_id AND a.branch_id = b.id
    AND a.starts_at >= (k.today + g.day_offset)::timestamp AT TIME ZONE b.time_zone
    AND a.starts_at < (k.today + g.day_offset + 1)::timestamp AT TIME ZONE b.time_zone
GROUP BY b.clinic_id, b.id, k.today, g.day_offset;

INSERT INTO report_exports (clinic_id, requested_by, report_type, filters_json,
                            state, object_key, expires_at, error_code, created_at)
SELECT c.clinic_id, s.user_id, 'DAILY_BRANCH_METRICS',
       jsonb_build_object('from', k.today - n - 7, 'to', k.today - n),
       (ARRAY['QUEUED', 'RUNNING', 'READY', 'FAILED', 'EXPIRED'])[n],
       CASE WHEN n = 3 THEN format('demo/%s/report-%s.csv', c.slug, n) END,
       CASE WHEN n = 3 THEN k.loaded_at + interval '1 day' WHEN n = 5 THEN k.loaded_at - interval '1 day' END,
       CASE WHEN n = 4 THEN 'DEMO_EXPORT_TIMEOUT' END, k.loaded_at - interval '2 days'
FROM demo_clinics c JOIN demo_staff s ON s.clinic_id = c.clinic_id AND s.staff_no = 1
CROSS JOIN demo_clock k CROSS JOIN generate_series(1, 5) AS g(n);

INSERT INTO audit_events (clinic_id, actor_user_id, action, resource_type, resource_id, request_id, details_json)
SELECT m.clinic_id, s.user_id, CASE WHEN m.status = 'REVOKED' THEN 'MEMBERSHIP_REVOKED' ELSE 'MEMBERSHIP_CREATED' END,
       'STAFF_MEMBERSHIP', m.id, gen_random_uuid(), jsonb_build_object('status', m.status)
FROM staff_memberships m JOIN demo_staff s ON s.clinic_id = m.clinic_id AND s.staff_no = 1
UNION ALL
SELECT clinic_id, created_by, 'CLOSURE_CREATED', 'SCHEDULE_CLOSURE', id, gen_random_uuid(),
       jsonb_build_object('reasonCode', reason_code) FROM schedule_closures
UNION ALL
SELECT clinic_id, requested_by, 'EXPORT_REQUESTED', 'REPORT_EXPORT', id, gen_random_uuid(),
       jsonb_build_object('reportType', report_type) FROM report_exports;

DROP VIEW demo_clock;

COMMIT;

-- Quick verification in psql:
-- SELECT status, count(*) FROM appointments GROUP BY status ORDER BY status;
-- SELECT state, count(*) FROM notification_outbox GROUP BY state ORDER BY state;
-- SELECT slug, count(a.id) FROM clinics c LEFT JOIN appointments a ON a.clinic_id = c.id GROUP BY slug ORDER BY slug;
