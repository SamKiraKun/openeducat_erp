#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ops/database_dr/bin/common.sh
source "${SCRIPT_DIR}/common.sh"

load_env

for command_name in psql; do
    command -v "${command_name}" >/dev/null 2>&1 || die "Required command is missing from PATH: ${command_name}"
done

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

require_vars PRIMARY_ADMIN_PGHOST PRIMARY_ADMIN_PGPORT PRIMARY_ADMIN_PGUSER PRIMARY_ADMIN_DB SUBSCRIBER_ADMIN_PGHOST SUBSCRIBER_ADMIN_PGPORT SUBSCRIBER_ADMIN_PGUSER

warn_lag="${REPLICATION_LAG_WARN_SECONDS:-300}"
crit_lag="${REPLICATION_LAG_CRIT_SECONDS:-1800}"
warn_slot_bytes="${REPLICATION_SLOT_LAG_WARN_BYTES:-1073741824}"
crit_slot_bytes="${REPLICATION_SLOT_LAG_CRIT_BYTES:-5368709120}"

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

while IFS= read -r db_name; do
    subscription_name="$(subscription_name_for_db "${db_name}")"
    slot_name="$(slot_name_for_db "${db_name}")"
    subscriber_db_name="$(subscriber_db_name_for_db "${db_name}")"

    slot_row="$(
        run_psql_from_prefix PRIMARY_ADMIN "${PRIMARY_ADMIN_DB}" \
            --tuples-only \
            --no-align \
            --field-separator='|' \
            --command="SELECT slot_name, active::int, COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)::bigint, 0) FROM pg_replication_slots WHERE slot_name = '${slot_name}';"
    )"

    [[ -n "${slot_row}" ]] || die "Primary slot is missing: ${slot_name}"
    IFS='|' read -r _slot slot_active slot_lag_bytes <<< "${slot_row}"

    if [[ "${slot_active}" != "1" ]]; then
        die "Primary slot is inactive: ${slot_name}"
    fi

    if (( slot_lag_bytes >= crit_slot_bytes )); then
        die "Primary slot lag is critical for ${slot_name}: ${slot_lag_bytes} bytes"
    fi

    if (( slot_lag_bytes >= warn_slot_bytes )); then
        log "WARNING: primary slot lag is high for ${slot_name}: ${slot_lag_bytes} bytes"
    fi

    subscriber_row="$(
        run_psql_from_prefix SUBSCRIBER_ADMIN "${subscriber_db_name}" \
            --tuples-only \
            --no-align \
            --field-separator='|' \
            --command="SELECT subname, COALESCE(EXTRACT(EPOCH FROM now() - latest_end_time)::bigint, -1), COALESCE(last_msg_receipt_time::text, ''), COALESCE(latest_end_time::text, '') FROM pg_stat_subscription WHERE subname = '${subscription_name}';"
    )"

    [[ -n "${subscriber_row}" ]] || die "Subscription stats are missing on ${subscriber_db_name}: ${subscription_name}"
    IFS='|' read -r _sub lag_seconds last_receipt latest_end <<< "${subscriber_row}"

    if (( lag_seconds < 0 )); then
        die "Subscription has not applied any data yet on ${subscriber_db_name}: ${subscription_name}"
    fi

    if (( lag_seconds >= crit_lag )); then
        die "Subscription lag is critical on ${subscriber_db_name}: ${subscription_name} (${lag_seconds}s)"
    fi

    if (( lag_seconds >= warn_lag )); then
        log "WARNING: subscription lag is high on ${subscriber_db_name}: ${subscription_name} (${lag_seconds}s)"
    fi

    log "Replication healthy for ${db_name}: lag=${lag_seconds}s last_receipt=${last_receipt} latest_end=${latest_end}"
done < <(list_databases)
