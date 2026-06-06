#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OPS_ROOT="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_ENV_FILE="${OPS_ROOT}/.env"
ENV_FILE="${ENV_FILE:-${DEFAULT_ENV_FILE}}"
DEFAULT_REPO_ROOT="$(CDPATH='' cd -- "${OPS_ROOT}/../.." && pwd)"

log() {
    printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

load_env() {
    if [[ -f "${ENV_FILE}" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "${ENV_FILE}"
        set +a
        log "Loaded configuration from ${ENV_FILE}"
    else
        log "No environment file found at ${ENV_FILE}; using current shell environment"
    fi
}

require_vars() {
    local missing=()
    local name

    for name in "$@"; do
        if [[ -z "${!name:-}" ]]; then
            missing+=("${name}")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        die "Missing required environment variables: ${missing[*]}"
    fi
}

sql_quote_literal() {
    printf '%s' "$1" | sed "s/'/''/g"
}

list_databases() {
    local -a dbs=()

    require_vars ODOO_DATABASES
    # Odoo database names do not contain spaces; whitespace separation keeps the
    # env file simple for single-tenant and small multi-tenant setups.
    read -r -a dbs <<< "${ODOO_DATABASES}"
    printf '%s\n' "${dbs[@]}"
}

filestore_dir() {
    local db_name="$1"
    printf '%s/filestore/%s\n' "${ODOO_DATA_DIR%/}" "${db_name}"
}

ensure_dir() {
    mkdir -p -- "$1"
}

repo_root() {
    printf '%s\n' "${REPO_ROOT:-${DEFAULT_REPO_ROOT}}"
}

safe_prune_backup_sets() {
    local root="$1"
    local keep="$2"
    local root_abs
    local -a to_delete=()
    local -a entries=()
    local idx

    [[ -d "${root}" ]] || return 0
    [[ "${keep}" =~ ^[0-9]+$ ]] || die "BACKUP_SET_RETENTION must be numeric, got: ${keep}"
    (( keep >= 1 )) || die "BACKUP_SET_RETENTION must be at least 1"

    root_abs="$(cd -- "${root}" && pwd)"
    mapfile -t entries < <(find "${root_abs}" -mindepth 1 -maxdepth 1 -type d ! -name latest -printf '%P\n' | sort)

    if (( ${#entries[@]} <= keep )); then
        return 0
    fi

    for (( idx = 0; idx < ${#entries[@]} - keep; idx++ )); do
        to_delete+=("${entries[idx]}")
    done

    for entry in "${to_delete[@]}"; do
        local target="${root_abs}/${entry}"

        [[ "${target}" == "${root_abs}/"* ]] || die "Refusing to prune unexpected path: ${target}"
        log "Pruning old backup set ${target}"
        rm -rf -- "${target}"
    done
}

restore_conn_args() {
    require_vars RESTORE_PGHOST RESTORE_PGPORT RESTORE_PGUSER
    printf -- '--host=%s --port=%s --username=%s' \
        "${RESTORE_PGHOST}" \
        "${RESTORE_PGPORT}" \
        "${RESTORE_PGUSER}"
}

conn_args_from_prefix() {
    local prefix="$1"
    local host_var="${prefix}_PGHOST"
    local port_var="${prefix}_PGPORT"
    local user_var="${prefix}_PGUSER"

    require_vars "${host_var}" "${port_var}" "${user_var}"
    printf -- '--host=%s --port=%s --username=%s' \
        "${!host_var}" \
        "${!port_var}" \
        "${!user_var}"
}

sanitize_name() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' '_'
}

publication_name_for_db() {
    local db_name="$1"
    printf '%s%s\n' "${PUBLICATION_PREFIX:-openeducat_pub_}" "$(sanitize_name "${db_name}")"
}

subscription_name_for_db() {
    local db_name="$1"
    printf '%s%s\n' "${SUBSCRIPTION_PREFIX:-openeducat_sub_}" "$(sanitize_name "${db_name}")"
}

slot_name_for_db() {
    local db_name="$1"
    printf '%s%s\n' "${REPLICATION_SLOT_PREFIX:-openeducat_slot_}" "$(sanitize_name "${db_name}")"
}

subscriber_db_name_for_db() {
    local db_name="$1"
    local prefix="${SUBSCRIBER_DB_PREFIX:-${RESTORE_TARGET_DB_PREFIX:-}}"
    local suffix="${SUBSCRIBER_DB_SUFFIX:-${RESTORE_TARGET_DB_SUFFIX:-}}"

    printf '%s%s%s\n' "${prefix}" "${db_name}" "${suffix}"
}
