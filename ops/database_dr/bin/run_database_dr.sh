#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$(id -un)" == "odoo" ]]; then
    cat >&2 <<'EOF'
ERROR: do not run this wrapper as the odoo service account.
Run it as the SSH user that owns the cloned repo and the .env file, for example:
  ENV_FILE=$PWD/ops/database_dr/.env bash ops/database_dr/bin/run_database_dr.sh discover
EOF
    exit 1
fi

# shellcheck source=ops/database_dr/bin/common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
    cat <<'EOF'
Usage:
  run_database_dr.sh discover
  run_database_dr.sh stage1 [--skip-restore-drill] [--skip-cloudinary-health]
  run_database_dr.sh stage2-check
  run_database_dr.sh stage2-print-subscriber-sql
  run_database_dr.sh stage2-apply [--skip-subscriber]
  run_database_dr.sh stage2-verify

Modes:
  discover
      Run only the environment discovery report.

  stage1
      Run the Stage 1 workflow in order:
      discover -> backup -> restore drill -> backup health -> Cloudinary health.
      Use --skip-restore-drill if the restore target is not ready yet.
      Use --skip-cloudinary-health if Cloudinary is enabled but you want to skip
      that API check for this run.

  stage2-check
      Run only the logical replication prerequisite checks.

  stage2-print-subscriber-sql
      Print the subscriber SQL instead of applying it.

  stage2-apply
      Apply the Stage 2 primary-side changes, then apply the subscriber
      subscription, verify the objects, and run replication health checks.
      Use --skip-subscriber if you only want the primary-side publication/user
      setup in this run. In that case the wrapper skips subscriber verification
      on purpose.

  stage2-verify
      Verify replication objects and current replication health.

The wrapper reads the same ENV_FILE / ops/database_dr/.env configuration as the
underlying scripts.
EOF
}

run_step() {
    local step_name="$1"
    shift

    log "Running ${step_name}"
    "$@"
}

require_real_vars() {
    local missing=()
    local name
    local value

    for name in "$@"; do
        value="${!name:-}"
        if [[ -z "${value}" || "${value}" == "CHANGE_ME" ]]; then
            missing+=("${name}")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        die "These variables must be set to real values before this workflow can run: ${missing[*]}"
    fi
}

run_discover() {
    run_step "discovery" "${SCRIPT_DIR}/discover_odoo_env.sh"
}

require_effective_subscriber_vars() {
    if [[ -n "${SUBSCRIBER_ADMIN_PGHOST:-}" || -n "${SUBSCRIBER_ADMIN_PGPORT:-}" || -n "${SUBSCRIBER_ADMIN_PGUSER:-}" ]]; then
        require_real_vars SUBSCRIBER_ADMIN_PGHOST SUBSCRIBER_ADMIN_PGPORT SUBSCRIBER_ADMIN_PGUSER
    else
        require_real_vars RESTORE_PGHOST RESTORE_PGPORT RESTORE_PGUSER
    fi
}

run_stage1() {
    local skip_restore_drill="$1"
    local skip_cloudinary_health="$2"

    run_discover
    run_step "backup" "${SCRIPT_DIR}/backup_openeducat.sh"

    if (( skip_restore_drill == 0 )); then
        require_real_vars RESTORE_PGHOST RESTORE_PGPORT RESTORE_PGUSER
        run_step "restore drill" "${SCRIPT_DIR}/run_restore_drill.sh"
    else
        log "Skipping restore drill by request"
        if [[ -n "${RESTORE_DRILL_MAX_AGE_DAYS:-}" ]]; then
            log "Backup health may still fail if RESTORE_DRILL_MAX_AGE_DAYS expects a recent latest_validated restore drill"
        fi
    fi

    run_step "backup health" "${SCRIPT_DIR}/check_backup_health.sh"

    if (( skip_cloudinary_health == 0 )); then
        run_step "cloudinary health" "${SCRIPT_DIR}/check_cloudinary_health.sh"
    else
        log "Skipping Cloudinary health by request"
    fi
}

run_stage2_check() {
    require_real_vars PRIMARY_ADMIN_PGHOST PRIMARY_ADMIN_PGPORT PRIMARY_ADMIN_PGUSER PRIMARY_ADMIN_DB
    run_step "replication prereqs" "${SCRIPT_DIR}/setup_logical_replication.sh" check-prereqs
}

run_stage2_apply() {
    local skip_subscriber="$1"

    require_real_vars \
        PRIMARY_ADMIN_PGHOST PRIMARY_ADMIN_PGPORT PRIMARY_ADMIN_PGUSER PRIMARY_ADMIN_DB \
        PRIMARY_PUBLIC_HOST PRIMARY_PUBLIC_PORT REPLICATION_USER REPLICATION_PASSWORD

    run_step "primary replication setup" "${SCRIPT_DIR}/setup_logical_replication.sh" apply-primary

    if (( skip_subscriber == 0 )); then
        require_effective_subscriber_vars
        run_step "subscriber replication setup" "${SCRIPT_DIR}/setup_logical_replication.sh" apply-subscriber
        run_step "replication verification" "${SCRIPT_DIR}/setup_logical_replication.sh" verify
        run_step "replication health" "${SCRIPT_DIR}/check_replication_health.sh"
    else
        log "Skipping subscriber creation by request"
    fi
}

run_stage2_verify() {
    require_real_vars PRIMARY_ADMIN_PGHOST PRIMARY_ADMIN_PGPORT PRIMARY_ADMIN_PGUSER PRIMARY_ADMIN_DB
    require_effective_subscriber_vars

    run_step "replication verification" "${SCRIPT_DIR}/setup_logical_replication.sh" verify
    run_step "replication health" "${SCRIPT_DIR}/check_replication_health.sh"
}

load_env

mode="${1:-help}"
shift || true

skip_restore_drill=0
skip_cloudinary_health=0
skip_subscriber=0

while (( $# > 0 )); do
    case "$1" in
        --skip-restore-drill)
            skip_restore_drill=1
            ;;
        --skip-cloudinary-health)
            skip_cloudinary_health=1
            ;;
        --skip-subscriber)
            skip_subscriber=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
    shift
done

case "${mode}" in
    discover)
        run_discover
        ;;
    stage1)
        run_stage1 "${skip_restore_drill}" "${skip_cloudinary_health}"
        ;;
    stage2-check)
        run_stage2_check
        ;;
    stage2-print-subscriber-sql)
        require_real_vars PRIMARY_PUBLIC_HOST PRIMARY_PUBLIC_PORT REPLICATION_USER REPLICATION_PASSWORD
        run_step "subscriber SQL generation" "${SCRIPT_DIR}/setup_logical_replication.sh" print-subscriber-sql
        ;;
    stage2-apply)
        run_stage2_apply "${skip_subscriber}"
        ;;
    stage2-verify)
        run_stage2_verify
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
