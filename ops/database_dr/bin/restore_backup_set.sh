#!/usr/bin/env bash

set -euo pipefail
umask 077

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ops/database_dr/bin/common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
    cat <<'EOF'
Usage:
  restore_backup_set.sh <backup_set_path> [database_name]

Examples:
  restore_backup_set.sh /var/backups/openeducat/latest
  restore_backup_set.sh /var/backups/openeducat/2026-06-04_02-15-00 openeducat_prod
EOF
}

load_env
require_vars RESTORE_PGHOST RESTORE_PGPORT RESTORE_PGUSER

for command_name in createdb dropdb pg_restore; do
    command -v "${command_name}" >/dev/null 2>&1 || die "Required command is missing from PATH: ${command_name}"
done

if [[ -n "${RESTORE_FILESTORE_ROOT:-}" ]]; then
    command -v tar >/dev/null 2>&1 || die "Required command is missing from PATH: tar"
fi

backup_set="${1:-}"
single_db="${2:-}"

if [[ -z "${backup_set}" ]]; then
    usage
    exit 1
fi

if [[ ! -d "${backup_set}" ]]; then
    die "Backup set path does not exist: ${backup_set}"
fi

backup_set="$(cd -- "${backup_set}" && pwd)"
restore_sslmode="${RESTORE_PGSSLMODE:-require}"
restore_admin_db="${RESTORE_ADMIN_DB:-postgres}"
restore_prefix="${RESTORE_TARGET_DB_PREFIX:-}"
restore_suffix="${RESTORE_TARGET_DB_SUFFIX:-}"
restore_record_path="${backup_set}/restore_validation.env"

if [[ -n "${RESTORE_PGPASSWORD:-}" ]]; then
    export PGPASSWORD="${RESTORE_PGPASSWORD}"
else
    unset PGPASSWORD || true
fi

export PGSSLMODE="${restore_sslmode}"

if [[ -f "${backup_set}/checksums.txt" ]] && command -v sha256sum >/dev/null 2>&1; then
    log "Verifying backup checksums in ${backup_set}"
    (
        cd -- "${backup_set}"
        sha256sum -c checksums.txt
    )
fi

if [[ -n "${single_db}" ]]; then
    dbs=("${single_db}")
else
    mapfile -t dbs < <(list_databases)
fi

for db_name in "${dbs[@]}"; do
    dump_path="${backup_set}/${db_name}.dump"
    archive_path="${backup_set}/${db_name}_filestore.tar.gz"
    target_db="${restore_prefix}${db_name}${restore_suffix}"

    [[ -f "${dump_path}" ]] || die "Dump not found for ${db_name}: ${dump_path}"

    log "Recreating target database ${target_db} on ${RESTORE_PGHOST}:${RESTORE_PGPORT}"
    dropdb \
        $(restore_conn_args) \
        --maintenance-db="${restore_admin_db}" \
        --if-exists \
        "${target_db}"

    createdb \
        $(restore_conn_args) \
        --maintenance-db="${restore_admin_db}" \
        "${target_db}"

    log "Restoring ${dump_path} into ${target_db}"
    pg_restore \
        $(restore_conn_args) \
        --dbname="${target_db}" \
        --clean \
        --if-exists \
        --no-owner \
        --no-privileges \
        "${dump_path}"

    if [[ -n "${RESTORE_FILESTORE_ROOT:-}" && -f "${archive_path}" ]]; then
        ensure_dir "${RESTORE_FILESTORE_ROOT}"
        log "Extracting ${archive_path} into ${RESTORE_FILESTORE_ROOT}"
        tar -xzf "${archive_path}" -C "${RESTORE_FILESTORE_ROOT}"
    elif [[ -n "${RESTORE_FILESTORE_ROOT:-}" ]]; then
        log "WARNING: filestore archive not found for ${db_name}: ${archive_path}"
    fi
done

{
    printf 'validated_at_utc=%s\n' "$(date -u +%FT%TZ)"
    printf 'restore_target_host=%s\n' "${RESTORE_PGHOST}"
    printf 'restore_target_port=%s\n' "${RESTORE_PGPORT}"
    printf 'restore_target_prefix=%s\n' "${restore_prefix}"
    printf 'restore_target_suffix=%s\n' "${restore_suffix}"
    printf 'validated_databases=%s\n' "${single_db:-${ODOO_DATABASES:-}}"
} > "${restore_record_path}"

if [[ -n "${BACKUP_ROOT:-}" ]]; then
    latest_validated_path="${BACKUP_ROOT%/}/latest_validated"
    backup_root_abs="$(cd -- "${BACKUP_ROOT}" && pwd)"

    if [[ "${backup_set}" == "${backup_root_abs}/"* ]]; then
        ln -sfn "$(basename "${backup_set}")" "${latest_validated_path}"
    fi
fi

log "Restore completed for backup set ${backup_set}"
