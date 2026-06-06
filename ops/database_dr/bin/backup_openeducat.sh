#!/usr/bin/env bash

set -euo pipefail
umask 077

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ops/database_dr/bin/common.sh
source "${SCRIPT_DIR}/common.sh"

load_env
require_vars ODOO_DATA_DIR ODOO_DATABASES BACKUP_ROOT PGHOST PGPORT PGUSER

for command_name in pg_dump tar; do
    command -v "${command_name}" >/dev/null 2>&1 || die "Required command is missing from PATH: ${command_name}"
done

timestamp="$(date +%F_%H-%M-%S)"
backup_root="${BACKUP_ROOT%/}"
run_dir="${backup_root}/${timestamp}"
manifest_path="${run_dir}/backup_manifest.env"
checksums_path="${run_dir}/checksums.txt"
repo_dir="$(repo_root)"

ensure_dir "${run_dir}"
log "Creating backup set in ${run_dir}"

if [[ -n "${ODOO_CONF:-}" && -f "${ODOO_CONF}" ]]; then
    cp -- "${ODOO_CONF}" "${run_dir}/odoo.conf.snapshot"
fi

{
    printf 'created_at_utc=%s\n' "$(date -u +%FT%TZ)"
    printf 'backup_host=%s\n' "$(hostname)"
    printf 'odoo_conf=%s\n' "${ODOO_CONF:-}"
    printf 'odoo_data_dir=%s\n' "${ODOO_DATA_DIR}"
    printf 'odoo_databases=%s\n' "${ODOO_DATABASES}"
    printf 'pg_host=%s\n' "${PGHOST}"
    printf 'pg_port=%s\n' "${PGPORT}"
    printf 'pg_user=%s\n' "${PGUSER}"
    printf 'repo_root=%s\n' "${repo_dir}"
} > "${manifest_path}"

if command -v git >/dev/null 2>&1 && [[ -d "${repo_dir}/.git" ]]; then
    {
        printf 'repo_git_revision=%s\n' "$(git -C "${repo_dir}" rev-parse HEAD)"
        if git -C "${repo_dir}" diff --quiet --ignore-submodules HEAD --; then
            printf 'repo_git_dirty=0\n'
        else
            printf 'repo_git_dirty=1\n'
        fi
    } >> "${manifest_path}"
fi

if [[ "${INCLUDE_REPO_ARCHIVE:-0}" == "1" ]]; then
    repo_archive_name="${REPO_ARCHIVE_NAME:-openeducat_erp_repo.tar.gz}"
    repo_archive_path="${run_dir}/${repo_archive_name}"

    [[ -d "${repo_dir}" ]] || die "Configured REPO_ROOT does not exist: ${repo_dir}"
    log "Archiving deployed addons repository from ${repo_dir}"
    tar \
        --exclude=.git \
        --exclude=ops/database_dr/.env \
        -C "${repo_dir}" \
        -czf "${repo_archive_path}" \
        .
fi

while IFS= read -r db_name; do
    dump_path="${run_dir}/${db_name}.dump"
    filestore_path="$(filestore_dir "${db_name}")"
    archive_path="${run_dir}/${db_name}_filestore.tar.gz"

    log "Dumping PostgreSQL database ${db_name}"
    pg_dump \
        --host="${PGHOST}" \
        --port="${PGPORT}" \
        --username="${PGUSER}" \
        --format=custom \
        --blobs \
        --file="${dump_path}" \
        "${db_name}"

    if command -v sha256sum >/dev/null 2>&1; then
        (
            cd -- "${run_dir}"
            sha256sum "$(basename "${dump_path}")" >> "$(basename "${checksums_path}")"
        )
    fi

    if [[ -d "${filestore_path}" ]]; then
        log "Archiving filestore ${filestore_path}"
        tar -C "$(dirname "${filestore_path}")" -czf "${archive_path}" "$(basename "${filestore_path}")"

        if command -v sha256sum >/dev/null 2>&1; then
            (
                cd -- "${run_dir}"
                sha256sum "$(basename "${archive_path}")" >> "$(basename "${checksums_path}")"
            )
        fi
    else
        log "WARNING: filestore not found for ${db_name}, expected ${filestore_path}"
    fi
done < <(list_databases)

if [[ "${INCLUDE_REPO_ARCHIVE:-0}" == "1" && -f "${repo_archive_path:-}" ]] && command -v sha256sum >/dev/null 2>&1; then
    (
        cd -- "${run_dir}"
        sha256sum "$(basename "${repo_archive_path}")" >> "$(basename "${checksums_path}")"
    )
fi

ln -sfn "${timestamp}" "${backup_root}/latest"

if [[ -n "${BACKUP_SET_RETENTION:-}" ]]; then
    safe_prune_backup_sets "${backup_root}" "${BACKUP_SET_RETENTION}"
fi

log "Backup set completed: ${run_dir}"
