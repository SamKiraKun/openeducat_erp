#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ops/database_dr/bin/common.sh
source "${SCRIPT_DIR}/common.sh"

load_env

if [[ "${CLOUDINARY_ENABLED:-0}" != "1" ]]; then
    log "Cloudinary health check skipped because CLOUDINARY_ENABLED is not 1"
    exit 0
fi

require_vars \
    CLOUDINARY_CLOUD_NAME \
    CLOUDINARY_API_KEY \
    CLOUDINARY_API_SECRET \
    CLOUDINARY_SCHOOL_CODE \
    CLOUDINARY_DELIVERY_MODE

command -v curl >/dev/null 2>&1 || die "curl is required for Cloudinary health checks"

usage_url="https://api.cloudinary.com/v1_1/${CLOUDINARY_CLOUD_NAME}/usage"
response="$(
    curl \
        --fail \
        --silent \
        --show-error \
        --user "${CLOUDINARY_API_KEY}:${CLOUDINARY_API_SECRET}" \
        "${usage_url}"
)"

printf '%s' "${response}" | grep -q '"plan"' || die "Cloudinary usage response did not contain the expected plan payload"

log "Cloudinary API credentials are valid for cloud ${CLOUDINARY_CLOUD_NAME}"
log "Delivery mode=${CLOUDINARY_DELIVERY_MODE} folder_prefix=${CLOUDINARY_FOLDER_PREFIX:-openeducat} environment=${CLOUDINARY_ENVIRONMENT:-prod} school_code=${CLOUDINARY_SCHOOL_CODE:-unset}"
