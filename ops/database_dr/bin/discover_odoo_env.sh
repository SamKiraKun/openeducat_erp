#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ops/database_dr/bin/common.sh
source "${SCRIPT_DIR}/common.sh"

load_env

log "Server operating system"
if [[ -r /etc/os-release ]]; then
    awk -F '=' '
        $1 == "PRETTY_NAME" {
            gsub(/^"/, "", $2)
            gsub(/"$/, "", $2)
            print $2
        }
    ' /etc/os-release
else
    uname -srvmo
fi

if [[ -n "${ODOO_CONF:-}" && -f "${ODOO_CONF}" ]]; then
    log "Inspecting ${ODOO_CONF}"
    awk -F '=' '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            key=$1
            value=$2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if (key == "db_host" || key == "db_port" || key == "db_user" || key == "data_dir") {
                printf "%s=%s\n", key, value
            }
        }
    ' "${ODOO_CONF}"
else
    log "ODOO_CONF is not set to a readable file; skipping config inspection"
fi

if command -v psql >/dev/null 2>&1; then
    if [[ -n "${PGHOST:-}" && -n "${PGPORT:-}" && -n "${PGUSER:-}" ]]; then
        log "Querying PostgreSQL server metadata"
        psql \
            --host="${PGHOST}" \
            --port="${PGPORT}" \
            --username="${PGUSER}" \
            --dbname=postgres \
            --tuples-only \
            --no-align \
            --command="SHOW server_version;"

        log "Listing non-template databases with sizes"
        psql \
            --host="${PGHOST}" \
            --port="${PGPORT}" \
            --username="${PGUSER}" \
            --dbname=postgres \
            --tuples-only \
            --no-align \
            --command="SELECT datname || '|' || pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE datistemplate = false ORDER BY datname;"
    else
        log "PGHOST/PGPORT/PGUSER are incomplete; skipping PostgreSQL discovery"
    fi
else
    log "psql is not available on PATH; skipping PostgreSQL discovery"
fi

if [[ -n "${ODOO_DATA_DIR:-}" ]]; then
    log "Inspecting filestore directories under ${ODOO_DATA_DIR%/}/filestore"

    if [[ -n "${ODOO_DATABASES:-}" ]]; then
        while IFS= read -r db_name; do
            fs_dir="$(filestore_dir "${db_name}")"
            if [[ -d "${fs_dir}" ]]; then
                du -sh "${fs_dir}"
            else
                log "Filestore missing for ${db_name}: ${fs_dir}"
            fi
        done < <(list_databases)
    elif [[ -d "${ODOO_DATA_DIR%/}/filestore" ]]; then
        declare -a filestore_dirs=()
        mapfile -t filestore_dirs < <(find "${ODOO_DATA_DIR%/}/filestore" -mindepth 1 -maxdepth 1 -type d | sort)

        if (( ${#filestore_dirs[@]} > 0 )); then
            du -sh "${filestore_dirs[@]}"
        else
            log "Filestore root exists but contains no database directories"
        fi
    else
        log "No filestore directory found at ${ODOO_DATA_DIR%/}/filestore"
    fi
else
    log "ODOO_DATA_DIR is not set; skipping filestore discovery"
fi

repo_dir="$(repo_root)"
if command -v git >/dev/null 2>&1 && [[ -d "${repo_dir}/.git" ]]; then
    log "Inspecting deployed addons repository"
    git -C "${repo_dir}" rev-parse HEAD
    git -C "${repo_dir}" status --short
fi
