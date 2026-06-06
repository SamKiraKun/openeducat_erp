#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ops/database_dr/bin/common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
    cat <<'EOF'
Usage:
  setup_logical_replication.sh check-prereqs
  setup_logical_replication.sh apply-primary
  setup_logical_replication.sh print-subscriber-sql
  setup_logical_replication.sh apply-subscriber
  setup_logical_replication.sh verify
EOF
}

load_env

for command_name in psql; do
    command -v "${command_name}" >/dev/null 2>&1 || die "Required command is missing from PATH: ${command_name}"
done

mode="${1:-help}"

if [[ -z "${SUBSCRIBER_ADMIN_PGHOST:-}" && -n "${RESTORE_PGHOST:-}" ]]; then
    SUBSCRIBER_ADMIN_PGHOST="${RESTORE_PGHOST}"
    SUBSCRIBER_ADMIN_PGPORT="${RESTORE_PGPORT:-5432}"
    SUBSCRIBER_ADMIN_PGUSER="${RESTORE_PGUSER:-}"
    SUBSCRIBER_ADMIN_PGPASSWORD="${RESTORE_PGPASSWORD:-}"
    SUBSCRIBER_ADMIN_PGSSLMODE="${RESTORE_PGSSLMODE:-require}"
fi

if [[ -z "${SUBSCRIBER_ADMIN_DB:-}" ]]; then
    SUBSCRIBER_ADMIN_DB="${RESTORE_ADMIN_DB:-postgres}"
fi

run_psql_from_prefix() {
    local prefix="$1"
    local db_name="$2"
    shift 2

    local password_var="${prefix}_PGPASSWORD"
    local sslmode_var="${prefix}_PGSSLMODE"
    local password="${!password_var:-}"
    local sslmode="${!sslmode_var:-prefer}"

    if [[ -n "${password}" ]]; then
        PGPASSWORD="${password}" PGSSLMODE="${sslmode}" \
            psql $(conn_args_from_prefix "${prefix}") --dbname="${db_name}" -v ON_ERROR_STOP=1 "$@"
    else
        PGSSLMODE="${sslmode}" \
            psql $(conn_args_from_prefix "${prefix}") --dbname="${db_name}" -v ON_ERROR_STOP=1 "$@"
    fi
}

check_primary_prereqs() {
    require_vars PRIMARY_ADMIN_PGHOST PRIMARY_ADMIN_PGPORT PRIMARY_ADMIN_PGUSER PRIMARY_ADMIN_DB

    log "Checking primary PostgreSQL logical replication prerequisites"
    run_psql_from_prefix PRIMARY_ADMIN "${PRIMARY_ADMIN_DB}" \
        --tuples-only \
        --no-align \
        --field-separator='|' \
        --command="SELECT current_setting('server_version'), current_setting('wal_level'), current_setting('max_replication_slots'), current_setting('max_wal_senders');" \
        | while IFS='|' read -r version wal_level max_slots max_senders; do
            log "Primary version=${version} wal_level=${wal_level} max_replication_slots=${max_slots} max_wal_senders=${max_senders}"

            [[ "${wal_level}" == "logical" ]] || die "Primary wal_level must be logical, got ${wal_level}"
            (( max_slots >= 1 )) || die "Primary max_replication_slots must be >= 1"
            (( max_senders >= 1 )) || die "Primary max_wal_senders must be >= 1"
        done

    while IFS= read -r db_name; do
        run_psql_from_prefix PRIMARY_ADMIN "${PRIMARY_ADMIN_DB}" \
            --tuples-only \
            --no-align \
            --command="SELECT 1 FROM pg_database WHERE datname = '${db_name}';" \
            | grep -qx '1' || die "Primary database does not exist: ${db_name}"
    done < <(list_databases)
}

apply_primary() {
    require_vars PRIMARY_ADMIN_PGHOST PRIMARY_ADMIN_PGPORT PRIMARY_ADMIN_PGUSER PRIMARY_ADMIN_DB REPLICATION_USER REPLICATION_PASSWORD

    primary_db_owner="${PRIMARY_DB_OWNER:-${PGUSER:-odoo}}"

    run_psql_from_prefix PRIMARY_ADMIN "${PRIMARY_ADMIN_DB}" \
        -v repl_user="${REPLICATION_USER}" \
        -v repl_password="${REPLICATION_PASSWORD}" \
        <<'SQL'
DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'repl_user') THEN
        EXECUTE format('CREATE ROLE %I WITH LOGIN REPLICATION PASSWORD %L', :'repl_user', :'repl_password');
    ELSE
        EXECUTE format('ALTER ROLE %I WITH LOGIN REPLICATION PASSWORD %L', :'repl_user', :'repl_password');
        EXECUTE format('ALTER ROLE %I WITH LOGIN REPLICATION', :'repl_user');
    END IF;
END
$do$;
SQL

    while IFS= read -r db_name; do
        publication_name="$(publication_name_for_db "${db_name}")"
        log "Creating publication ${publication_name} on ${db_name}"

        run_psql_from_prefix PRIMARY_ADMIN "${PRIMARY_ADMIN_DB}" \
            -v repl_user="${REPLICATION_USER}" \
            -v db_name="${db_name}" \
            --command="GRANT CONNECT ON DATABASE \"${db_name}\" TO \"${REPLICATION_USER}\";"

        run_psql_from_prefix PRIMARY_ADMIN "${db_name}" \
            -v repl_user="${REPLICATION_USER}" \
            -v pub_name="${publication_name}" \
            -v owner_role="${primary_db_owner}" \
            <<'SQL'
DO $do$
DECLARE
    schema_name text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = :'pub_name') THEN
        EXECUTE format('CREATE PUBLICATION %I FOR ALL TABLES', :'pub_name');
    END IF;

    FOR schema_name IN
        SELECT nspname
        FROM pg_namespace
        WHERE nspname NOT IN ('pg_catalog', 'information_schema')
          AND nspname NOT LIKE 'pg_toast%'
          AND nspname NOT LIKE 'pg_temp_%'
    LOOP
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', schema_name, :'repl_user');
        EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO %I', schema_name, :'repl_user');
        EXECUTE format('GRANT SELECT ON ALL SEQUENCES IN SCHEMA %I TO %I', schema_name, :'repl_user');
        EXECUTE format(
            'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT SELECT ON TABLES TO %I',
            :'owner_role', schema_name, :'repl_user'
        );
        EXECUTE format(
            'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT SELECT ON SEQUENCES TO %I',
            :'owner_role', schema_name, :'repl_user'
        );
    END LOOP;
END
$do$;
SQL
    done < <(list_databases)
}

print_subscriber_sql() {
    require_vars PRIMARY_PUBLIC_HOST PRIMARY_PUBLIC_PORT REPLICATION_USER REPLICATION_PASSWORD

    while IFS= read -r db_name; do
        publication_name="$(publication_name_for_db "${db_name}")"
        subscription_name="$(subscription_name_for_db "${db_name}")"
        slot_name="$(slot_name_for_db "${db_name}")"
        subscriber_db_name="$(subscriber_db_name_for_db "${db_name}")"

        cat <<EOF
-- Run this on the subscriber database ${subscriber_db_name}
CREATE SUBSCRIPTION ${subscription_name}
CONNECTION 'host=${PRIMARY_PUBLIC_HOST} port=${PRIMARY_PUBLIC_PORT} dbname=${db_name} user=${REPLICATION_USER} password=${REPLICATION_PASSWORD} sslmode=${PRIMARY_REPLICATION_SSLMODE:-require}'
PUBLICATION ${publication_name}
WITH (copy_data = true, create_slot = true, enabled = true, slot_name = '${slot_name}');

EOF
    done < <(list_databases)
}

apply_subscriber() {
    require_vars SUBSCRIBER_ADMIN_PGHOST SUBSCRIBER_ADMIN_PGPORT SUBSCRIBER_ADMIN_PGUSER SUBSCRIBER_ADMIN_DB PRIMARY_PUBLIC_HOST PRIMARY_PUBLIC_PORT REPLICATION_USER REPLICATION_PASSWORD

    while IFS= read -r db_name; do
        publication_name="$(publication_name_for_db "${db_name}")"
        subscription_name="$(subscription_name_for_db "${db_name}")"
        slot_name="$(slot_name_for_db "${db_name}")"
        subscriber_db_name="$(subscriber_db_name_for_db "${db_name}")"

        log "Ensuring subscriber database exists: ${subscriber_db_name}"
        run_psql_from_prefix SUBSCRIBER_ADMIN "${SUBSCRIBER_ADMIN_DB}" \
            --tuples-only \
            --no-align \
            --command="SELECT 1 FROM pg_database WHERE datname = '${subscriber_db_name}';" \
            | grep -qx '1' || die "Subscriber database does not exist: ${subscriber_db_name}"

        existing_sub="$(
            run_psql_from_prefix SUBSCRIBER_ADMIN "${subscriber_db_name}" \
                --tuples-only \
                --no-align \
                --command="SELECT 1 FROM pg_subscription WHERE subname = '${subscription_name}';"
        )"

        if [[ "${existing_sub}" == "1" ]]; then
            log "Subscription already exists on ${subscriber_db_name}: ${subscription_name}"
            continue
        fi

        log "Creating subscription ${subscription_name} on ${subscriber_db_name}"
        run_psql_from_prefix SUBSCRIBER_ADMIN "${subscriber_db_name}" \
            --command="CREATE SUBSCRIPTION ${subscription_name} CONNECTION 'host=${PRIMARY_PUBLIC_HOST} port=${PRIMARY_PUBLIC_PORT} dbname=${db_name} user=${REPLICATION_USER} password=${REPLICATION_PASSWORD} sslmode=${PRIMARY_REPLICATION_SSLMODE:-require}' PUBLICATION ${publication_name} WITH (copy_data = true, create_slot = true, enabled = true, slot_name = '${slot_name}');"
    done < <(list_databases)
}

verify_replication_objects() {
    while IFS= read -r db_name; do
        publication_name="$(publication_name_for_db "${db_name}")"
        subscription_name="$(subscription_name_for_db "${db_name}")"
        slot_name="$(slot_name_for_db "${db_name}")"
        subscriber_db_name="$(subscriber_db_name_for_db "${db_name}")"

        log "Verifying publication ${publication_name} on ${db_name}"
        run_psql_from_prefix PRIMARY_ADMIN "${db_name}" \
            --tuples-only \
            --no-align \
            --command="SELECT 1 FROM pg_publication WHERE pubname = '${publication_name}';" \
            | grep -qx '1' || die "Publication is missing on ${db_name}: ${publication_name}"

        log "Verifying slot ${slot_name} on primary"
        run_psql_from_prefix PRIMARY_ADMIN "${PRIMARY_ADMIN_DB}" \
            --tuples-only \
            --no-align \
            --command="SELECT 1 FROM pg_replication_slots WHERE slot_name = '${slot_name}';" \
            | grep -qx '1' || die "Replication slot is missing on primary: ${slot_name}"

        if [[ -n "${SUBSCRIBER_ADMIN_PGHOST:-}" && -n "${SUBSCRIBER_ADMIN_PGUSER:-}" ]]; then
            log "Verifying subscription ${subscription_name} on ${subscriber_db_name}"
            run_psql_from_prefix SUBSCRIBER_ADMIN "${subscriber_db_name}" \
                --tuples-only \
                --no-align \
                --command="SELECT 1 FROM pg_subscription WHERE subname = '${subscription_name}';" \
                | grep -qx '1' || die "Subscription is missing on ${subscriber_db_name}: ${subscription_name}"
        fi
    done < <(list_databases)
}

case "${mode}" in
    check-prereqs)
        check_primary_prereqs
        ;;
    apply-primary)
        check_primary_prereqs
        apply_primary
        ;;
    print-subscriber-sql)
        print_subscriber_sql
        ;;
    apply-subscriber)
        apply_subscriber
        ;;
    verify)
        verify_replication_objects
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
