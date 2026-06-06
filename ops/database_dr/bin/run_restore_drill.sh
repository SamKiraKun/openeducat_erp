#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ops/database_dr/bin/common.sh
source "${SCRIPT_DIR}/common.sh"

load_env
require_vars BACKUP_ROOT

exec "${SCRIPT_DIR}/restore_backup_set.sh" "${BACKUP_ROOT%/}/latest"
