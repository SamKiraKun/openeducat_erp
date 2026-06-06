#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ops/database_dr/bin/common.sh
source "${SCRIPT_DIR}/common.sh"

load_env
require_vars BACKUP_ROOT ODOO_DATABASES

latest_path="${BACKUP_ROOT%/}/latest"
[[ -e "${latest_path}" ]] || die "Latest backup link/path is missing: ${latest_path}"

latest_set="$(cd -- "${latest_path}" && pwd)"
manifest_path="${latest_set}/backup_manifest.env"
checksums_path="${latest_set}/checksums.txt"
max_age_hours="${BACKUP_MAX_AGE_HOURS:-26}"
disk_warn="${DISK_WARN_PERCENT:-80}"
disk_crit="${DISK_CRIT_PERCENT:-90}"

[[ -f "${manifest_path}" ]] || die "Backup manifest is missing: ${manifest_path}"

manifest_mtime="$(stat -c %Y "${manifest_path}")"
age_hours="$(( ($(date +%s) - manifest_mtime) / 3600 ))"

if (( age_hours > max_age_hours )); then
    die "Latest backup set is too old: ${latest_set} (${age_hours}h > ${max_age_hours}h)"
fi

while IFS= read -r db_name; do
    [[ -f "${latest_set}/${db_name}.dump" ]] || die "Missing database dump for ${db_name}"
    [[ -f "${latest_set}/${db_name}_filestore.tar.gz" ]] || die "Missing filestore archive for ${db_name}"
done < <(list_databases)

if [[ -n "${ODOO_CONF:-}" && -f "${ODOO_CONF}" ]]; then
    [[ -f "${latest_set}/odoo.conf.snapshot" ]] || die "Missing odoo.conf snapshot in ${latest_set}"
fi

if [[ "${INCLUDE_REPO_ARCHIVE:-0}" == "1" ]]; then
    repo_archive_name="${REPO_ARCHIVE_NAME:-openeducat_erp_repo.tar.gz}"
    [[ -f "${latest_set}/${repo_archive_name}" ]] || die "Missing repo archive in ${latest_set}"
fi

if [[ -f "${checksums_path}" ]]; then
    command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required to verify backup checksums"
    log "Verifying checksums in ${latest_set}"
    (
        cd -- "${latest_set}"
        sha256sum -c "$(basename "${checksums_path}")"
    )
fi

if [[ -n "${RESTORE_DRILL_MAX_AGE_DAYS:-}" ]]; then
    validated_link="${BACKUP_ROOT%/}/latest_validated"
    [[ -e "${validated_link}" ]] || die "Restore drill threshold is configured but latest_validated is missing"

    validated_set="$(cd -- "${validated_link}" && pwd)"
    validation_record="${validated_set}/restore_validation.env"
    [[ -f "${validation_record}" ]] || die "Restore drill threshold is configured but no validation record exists"

    validated_age_days="$(( ($(date +%s) - $(stat -c %Y "${validation_record}")) / 86400 ))"
    if (( validated_age_days > RESTORE_DRILL_MAX_AGE_DAYS )); then
        die "Latest restore drill is too old: ${validated_age_days}d > ${RESTORE_DRILL_MAX_AGE_DAYS}d"
    fi
fi

disk_used_percent="$(
    df -P "${BACKUP_ROOT}" | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }'
)"

if (( disk_used_percent >= disk_crit )); then
    die "Backup filesystem usage is critical: ${disk_used_percent}% >= ${disk_crit}%"
fi

if (( disk_used_percent >= disk_warn )); then
    log "WARNING: backup filesystem usage is high: ${disk_used_percent}% >= ${disk_warn}%"
fi

log "Backup health check passed for ${latest_set}"
