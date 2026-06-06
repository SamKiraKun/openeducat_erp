#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ops/database_dr/bin/common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
    cat <<'EOF'
Usage:
  migrate_cloudinary_attachments.sh [options]

Options:
  --db NAME            Odoo database name. Defaults to the first ODOO_DATABASES entry.
  --dry-run            Print the selected attachment set without modifying rows.
  --limit N            Batch size. Default: 100
  --model MODEL        Restrict by res_model.
  --mimetype TYPE      Restrict by mimetype or wildcard such as image/*.
  --since-id ID        Restrict to attachments with id >= ID.
  --retry-failed       Retry only rows marked as failed.
  --reverse            Restore remote-backed rows back into local Odoo storage.
  -h, --help           Show this help text.
EOF
}

load_env

odoo_bin="${ODOO_BIN:-odoo-bin}"
database_name=""
dry_run=0
limit=100
model_name=""
mimetype=""
since_id=""
retry_failed=0
reverse_mode=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --db)
            database_name="${2:-}"
            shift 2
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        --limit)
            limit="${2:-}"
            shift 2
            ;;
        --model)
            model_name="${2:-}"
            shift 2
            ;;
        --mimetype)
            mimetype="${2:-}"
            shift 2
            ;;
        --since-id)
            since_id="${2:-}"
            shift 2
            ;;
        --retry-failed)
            retry_failed=1
            shift
            ;;
        --reverse)
            reverse_mode=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            die "Unknown argument: $1"
            ;;
    esac
done

require_vars ODOO_CONF ODOO_DATABASES

if [[ -z "${database_name}" ]]; then
    while IFS= read -r candidate; do
        database_name="${candidate}"
        break
    done < <(list_databases)
fi

[[ -n "${database_name}" ]] || die "Could not determine the target Odoo database"
[[ "${limit}" =~ ^[0-9]+$ ]] || die "--limit must be numeric"
[[ -z "${since_id}" || "${since_id}" =~ ^[0-9]+$ ]] || die "--since-id must be numeric"

if ! command -v "${odoo_bin}" >/dev/null 2>&1 && [[ ! -x "${odoo_bin}" ]]; then
    die "ODOO_BIN is not executable or present on PATH: ${odoo_bin}"
fi

log "Running Cloudinary attachment migration on database ${database_name}"

CLOUDINARY_MIGRATION_DRY_RUN="${dry_run}" \
CLOUDINARY_MIGRATION_LIMIT="${limit}" \
CLOUDINARY_MIGRATION_MODEL="${model_name}" \
CLOUDINARY_MIGRATION_MIMETYPE="${mimetype}" \
CLOUDINARY_MIGRATION_SINCE_ID="${since_id}" \
CLOUDINARY_MIGRATION_RETRY_FAILED="${retry_failed}" \
CLOUDINARY_MIGRATION_REVERSE="${reverse_mode}" \
"${odoo_bin}" shell -c "${ODOO_CONF}" -d "${database_name}" <<'PY'
import json
import os

dry_run = os.environ.get('CLOUDINARY_MIGRATION_DRY_RUN', '0') == '1'
limit = int(os.environ.get('CLOUDINARY_MIGRATION_LIMIT', '100') or 100)
model_name = os.environ.get('CLOUDINARY_MIGRATION_MODEL') or False
mimetype = os.environ.get('CLOUDINARY_MIGRATION_MIMETYPE') or False
since_id = os.environ.get('CLOUDINARY_MIGRATION_SINCE_ID') or False
retry_failed = os.environ.get('CLOUDINARY_MIGRATION_RETRY_FAILED', '0') == '1'
reverse_mode = os.environ.get('CLOUDINARY_MIGRATION_REVERSE', '0') == '1'

attachment_model = env['ir.attachment']

if reverse_mode:
    result = attachment_model._cloudinary_restore_remote_attachments(
        dry_run=dry_run,
        limit=limit,
        model=model_name,
        mimetype=mimetype,
        since_id=since_id,
    )
else:
    result = attachment_model._cloudinary_migrate_existing_attachments(
        dry_run=dry_run,
        limit=limit,
        model=model_name,
        mimetype=mimetype,
        since_id=since_id,
        retry_failed=retry_failed,
    )

print(json.dumps(result, indent=2, sort_keys=True, default=str))
PY
