#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ops/database_dr/bin/common.sh
source "${SCRIPT_DIR}/common.sh"

load_env

require_vars \
    CLOUDINARY_ENABLED \
    CLOUDINARY_CLOUD_NAME \
    CLOUDINARY_API_KEY \
    CLOUDINARY_API_SECRET \
    CLOUDINARY_FOLDER_PREFIX \
    CLOUDINARY_ENVIRONMENT \
    CLOUDINARY_SCHOOL_CODE \
    PGHOST \
    PGPORT \
    PGUSER

if [[ "${CLOUDINARY_ENABLED}" != "1" ]]; then
    log "Inventory comparison skipped because CLOUDINARY_ENABLED is not 1"
    exit 0
fi

command -v curl >/dev/null 2>&1 || die "Required command is missing from PATH: curl"
command -v psql >/dev/null 2>&1 || die "Required command is missing from PATH: psql"

python_bin=""
for candidate in python3 python; do
    if command -v "${candidate}" >/dev/null 2>&1; then
        python_bin="${candidate}"
        break
    fi
done

[[ -n "${python_bin}" ]] || die "python3 or python is required for Cloudinary inventory checks"

db_password="${PGPASSWORD:-}"

run_psql() {
    local db_name="$1"
    local sql="$2"

    if [[ -n "${db_password}" ]]; then
        PGPASSWORD="${db_password}" \
            psql --host="${PGHOST}" --port="${PGPORT}" --username="${PGUSER}" --dbname="${db_name}" --tuples-only --no-align --command="${sql}"
    else
        psql --host="${PGHOST}" --port="${PGPORT}" --username="${PGUSER}" --dbname="${db_name}" --tuples-only --no-align --command="${sql}"
    fi
}

remote_count_for_prefix() {
    local prefix="$1"

    CLOUDINARY_COUNT_PREFIX="${prefix}" \
    CLOUDINARY_COUNT_CLOUD_NAME="${CLOUDINARY_CLOUD_NAME}" \
    CLOUDINARY_COUNT_API_KEY="${CLOUDINARY_API_KEY}" \
    CLOUDINARY_COUNT_API_SECRET="${CLOUDINARY_API_SECRET}" \
    CLOUDINARY_COUNT_DELIVERY_MODE="${CLOUDINARY_DELIVERY_MODE:-authenticated}" \
    "${python_bin}" - <<'PY'
import base64
import json
import os
import urllib.parse
import urllib.request

prefix = os.environ['CLOUDINARY_COUNT_PREFIX']
cloud_name = os.environ['CLOUDINARY_COUNT_CLOUD_NAME']
api_key = os.environ['CLOUDINARY_COUNT_API_KEY']
api_secret = os.environ['CLOUDINARY_COUNT_API_SECRET']
delivery_mode = os.environ.get('CLOUDINARY_COUNT_DELIVERY_MODE', 'authenticated')
auth_header = base64.b64encode(f"{api_key}:{api_secret}".encode()).decode()

def count_resources(resource_type):
    total = 0
    next_cursor = None

    while True:
        query = {
            'prefix': prefix,
            'max_results': '500',
        }
        if next_cursor:
            query['next_cursor'] = next_cursor

        url = (
            f"https://api.cloudinary.com/v1_1/{cloud_name}/resources/"
            f"{resource_type}/{delivery_mode}?{urllib.parse.urlencode(query)}"
        )
        request = urllib.request.Request(url)
        request.add_header('Authorization', f'Basic {auth_header}')
        with urllib.request.urlopen(request) as response:
            data = json.load(response)

        total += len(data.get('resources', []))
        next_cursor = data.get('next_cursor')
        if not next_cursor:
            break

    return total

print(count_resources('image') + count_resources('raw'))
PY
}

while IFS= read -r db_name; do
    prefix="${CLOUDINARY_FOLDER_PREFIX}/${CLOUDINARY_ENVIRONMENT}/${CLOUDINARY_SCHOOL_CODE:-}/${db_name}"
    prefix="${prefix//\/\//\/}"
    prefix="${prefix%/}"

    queue_table_exists="$(
        run_psql "${db_name}" \
            "SELECT to_regclass('public.openeducat_cloudinary_deletion_queue') IS NOT NULL;"
    )"
    queue_table_exists="$(printf '%s' "${queue_table_exists}" | tr -d '[:space:]')"

    queue_sql="0"
    if [[ "${queue_table_exists}" == "t" ]]; then
        queue_sql="(SELECT COUNT(*) FROM openeducat_cloudinary_deletion_queue WHERE state IN ('pending', 'failed'))"
    fi

    db_count="$(
        run_psql "${db_name}" \
            "SELECT
                (SELECT COUNT(*) FROM ir_attachment WHERE type = 'binary' AND cloudinary_public_id IS NOT NULL)
              + COALESCE(${queue_sql}, 0);"
    )"
    db_count="$(printf '%s' "${db_count}" | tr -d '[:space:]')"

    remote_count="$(remote_count_for_prefix "${prefix}")"
    remote_count="$(printf '%s' "${remote_count}" | tr -d '[:space:]')"

    printf '%s|db=%s|cloudinary=%s|prefix=%s\n' "${db_name}" "${db_count}" "${remote_count}" "${prefix}"

    [[ "${db_count}" == "${remote_count}" ]] || die "Inventory mismatch for ${db_name}: db=${db_count} cloudinary=${remote_count}"
done < <(list_databases)
