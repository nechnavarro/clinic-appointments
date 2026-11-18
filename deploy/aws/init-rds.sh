#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: bash deploy/aws/init-rds.sh <schema|demo> <rds-hostname> <rds-admin-user>\n' >&2
  exit 2
}

[[ $# -eq 3 ]] || usage
mode=$1
rds_host=$2
admin_user=$3
[[ $mode == schema || $mode == demo ]] || usage
[[ -n $rds_host && -n $admin_user ]] || usage

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source_sql="$root_dir/Clinic_Appointment_Database.sql"
root_cert="$root_dir/deploy/aws/certs/global-bundle.pem"

if [[ ! -r $source_sql || ! -r $root_cert ]]; then
  printf 'Expected %s and %s\n' "$source_sql" "$root_cert" >&2
  exit 1
fi

if ! grep -q '^-- DEVELOPMENT SEED\.' "$source_sql" || ! grep -q '^COMMIT;[[:space:]]*$' "$source_sql"; then
  printf 'The SQL file is missing its expected development seed marker or COMMIT.\n' >&2
  exit 1
fi

bootstrap_sql=$(mktemp)
trap 'rm -f -- "$bootstrap_sql"' EXIT

# Keep the original BEGIN and append permissions before the original COMMIT.
awk -v mode="$mode" '
  /^-- DEVELOPMENT SEED\./ { if (mode == "schema") skip_seed = 1 }
  /^COMMIT;[[:space:]]*$/ { exit }
  !skip_seed { print }
' "$source_sql" > "$bootstrap_sql"

cat >> "$bootstrap_sql" <<'SQL'
GRANT CONNECT ON DATABASE clinic_appointments TO clinic_app;
REVOKE CREATE ON SCHEMA public FROM PUBLIC, clinic_app;
GRANT USAGE ON SCHEMA public TO clinic_app;

GRANT SELECT, INSERT, UPDATE, DELETE ON
    public.users, public.staff_credentials, public.auth_challenges,
    public.clinics, public.branches, public.staff_memberships,
    public.membership_roles, public.membership_branches, public.providers,
    public.provider_branches, public.patient_profiles, public.staff_invitations,
    public.staff_invitation_branches, public.services, public.provider_services,
    public.working_hours, public.schedule_closures, public.appointments,
    public.idempotency_keys, public.notification_outbox,
    public.daily_branch_metrics, public.report_exports
TO clinic_app;

GRANT SELECT, INSERT ON public.appointment_events, public.audit_events TO clinic_app;
COMMIT;
SQL

printf 'Applying %s to clinic_appointments on %s as %s.\n' "$mode" "$rds_host" "$admin_user"
PGSSLMODE=verify-full PGSSLROOTCERT="$root_cert" \
  psql -X -W -v ON_ERROR_STOP=1 -h "$rds_host" -p 5432 \
  -U "$admin_user" -d clinic_appointments -f "$bootstrap_sql"
