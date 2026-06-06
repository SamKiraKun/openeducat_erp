#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"

log() {
    printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  sudo ENV_FILE=/absolute/path/to/ops/ubuntu_host/.env bash ops/ubuntu_host/install_openeducat_host.sh

This installer provisions the base Ubuntu host for OpenEduCat/Odoo:
  - apt packages
  - Odoo source checkout
  - addons sync
  - Python virtual environment
  - PostgreSQL role/database owner
  - odoo.conf
  - systemd service
  - nginx site
  - DR env + DR units
EOF
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this installer as root"
}

load_env() {
    if [[ -f "${ENV_FILE}" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "${ENV_FILE}"
        set +a
        log "Loaded installer configuration from ${ENV_FILE}"
    else
        die "Installer environment file not found: ${ENV_FILE}"
    fi
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
        die "These variables need real values in ${ENV_FILE}: ${missing[*]}"
    fi
}

ensure_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command is missing: $1"
}

sql_quote_literal() {
    printf '%s' "$1" | sed "s/'/''/g"
}

ensure_dir() {
    install -d -m "$2" "$1"
}

escape_sed_replacement() {
    printf '%s' "$1" | sed -e 's/[\/&|]/\\&/g'
}

render_template() {
    local template_path="$1"
    local output_path="$2"

    sed \
        -e "s|@@ODOO_USER@@|$(escape_sed_replacement "${ODOO_USER}")|g" \
        -e "s|@@ODOO_GROUP@@|$(escape_sed_replacement "${ODOO_GROUP}")|g" \
        -e "s|@@ODOO_CORE_PATH@@|$(escape_sed_replacement "${ODOO_CORE_PATH}")|g" \
        -e "s|@@ODOO_VENV_PATH@@|$(escape_sed_replacement "${ODOO_VENV_PATH}")|g" \
        -e "s|@@ODOO_CONF_PATH@@|$(escape_sed_replacement "${ODOO_CONF_PATH}")|g" \
        -e "s|@@ODOO_ADDONS_PATH@@|$(escape_sed_replacement "${ODOO_ADDONS_PATH}")|g" \
        -e "s|@@ODOO_ADMIN_PASSWORD@@|$(escape_sed_replacement "${ODOO_ADMIN_PASSWORD}")|g" \
        -e "s|@@ODOO_DATA_DIR@@|$(escape_sed_replacement "${ODOO_DATA_DIR}")|g" \
        -e "s|@@ODOO_DB_HOST@@|$(escape_sed_replacement "${ODOO_DB_HOST}")|g" \
        -e "s|@@ODOO_DB_PORT@@|$(escape_sed_replacement "${ODOO_DB_PORT}")|g" \
        -e "s|@@ODOO_DB_USER@@|$(escape_sed_replacement "${ODOO_DB_USER}")|g" \
        -e "s|@@ODOO_DB_PASSWORD@@|$(escape_sed_replacement "${ODOO_DB_PASSWORD}")|g" \
        -e "s|@@ODOO_DB_FILTER@@|$(escape_sed_replacement "${ODOO_DB_FILTER}")|g" \
        -e "s|@@ODOO_LIST_DB@@|$(escape_sed_replacement "${ODOO_LIST_DB}")|g" \
        -e "s|@@ODOO_PROXY_MODE@@|$(escape_sed_replacement "${ODOO_PROXY_MODE}")|g" \
        -e "s|@@ODOO_HTTP_INTERFACE@@|$(escape_sed_replacement "${ODOO_HTTP_INTERFACE}")|g" \
        -e "s|@@ODOO_HTTP_PORT@@|$(escape_sed_replacement "${ODOO_HTTP_PORT}")|g" \
        -e "s|@@ODOO_LONGPOLLING_PORT@@|$(escape_sed_replacement "${ODOO_LONGPOLLING_PORT}")|g" \
        -e "s|@@ODOO_WORKERS@@|$(escape_sed_replacement "${ODOO_WORKERS}")|g" \
        -e "s|@@ODOO_MAX_CRON_THREADS@@|$(escape_sed_replacement "${ODOO_MAX_CRON_THREADS}")|g" \
        -e "s|@@ODOO_LOGFILE@@|$(escape_sed_replacement "${ODOO_LOGFILE}")|g" \
        -e "s|@@SERVER_NAME@@|$(escape_sed_replacement "${PUBLIC_HOSTNAME}")|g" \
        -e "s|@@NGINX_CLIENT_MAX_BODY_SIZE@@|$(escape_sed_replacement "${NGINX_CLIENT_MAX_BODY_SIZE}")|g" \
        "${template_path}" > "${output_path}"
}

install_base_packages() {
    local -a packages=(
        ca-certificates
        curl
        fontconfig
        git
        nginx
        postgresql
        postgresql-client
        python3
        python3-dev
        python3-pip
        python3-venv
        rsync
        build-essential
        pkg-config
        libffi-dev
        libjpeg-dev
        liblcms2-dev
        libldap2-dev
        libpq-dev
        libsasl2-dev
        libtiff-dev
        libwebp-dev
        libxml2-dev
        libxslt1-dev
        libzip-dev
        zlib1g-dev
        xfonts-75dpi
        xfonts-base
    )

    if [[ "${INSTALL_WKHTMLTOPDF:-1}" == "1" ]]; then
        wkhtmltopdf_candidate="$(
            apt-cache policy wkhtmltopdf 2>/dev/null | awk '/Candidate:/ { print $2 }'
        )"

        if [[ -n "${wkhtmltopdf_candidate}" && "${wkhtmltopdf_candidate}" != "(none)" ]]; then
            packages+=(wkhtmltopdf)
        else
            log "WARNING: wkhtmltopdf is not available from apt on this Ubuntu release; skipping it. Install a compatible build manually if you need PDF reports."
        fi
    fi

    if [[ -n "${APT_PACKAGES_EXTRA:-}" ]]; then
        read -r -a extra_packages <<< "${APT_PACKAGES_EXTRA}"
        packages+=("${extra_packages[@]}")
    fi

    export DEBIAN_FRONTEND=noninteractive
    log "Installing Ubuntu packages"
    apt-get update
    apt-get install -y "${packages[@]}"
}

ensure_system_user() {
    if ! getent group "${ODOO_GROUP}" >/dev/null; then
        groupadd --system "${ODOO_GROUP}"
    fi

    if ! id -u "${ODOO_USER}" >/dev/null 2>&1; then
        useradd \
            --system \
            --gid "${ODOO_GROUP}" \
            --home-dir "${ODOO_HOME}" \
            --create-home \
            --shell /bin/bash \
            "${ODOO_USER}"
    fi
}

ensure_layout() {
    ensure_dir "${ODOO_HOME}" 755
    ensure_dir "$(dirname "${ADDONS_TARGET_REPO}")" 755
    ensure_dir "${ODOO_DATA_DIR}" 750
    ensure_dir "${ODOO_LOG_DIR}" 750
    ensure_dir /etc/odoo 750
    ensure_dir /etc/openeducat 750
    ensure_dir "${DR_BACKUP_ROOT}" 750
    ensure_dir "${DR_RESTORE_FILESTORE_ROOT}" 750

    chown -R "${ODOO_USER}:${ODOO_GROUP}" "${ODOO_HOME}" "${ODOO_DATA_DIR}" "${ODOO_LOG_DIR}" "${DR_BACKUP_ROOT}" "${DR_RESTORE_FILESTORE_ROOT}"
    chown root:"${ODOO_GROUP}" /etc/odoo /etc/openeducat
    chmod 750 /etc/odoo /etc/openeducat
}

prepare_repo_paths() {
    if [[ -n "${ADDONS_SOURCE_REPO:-}" ]]; then
        ADDONS_SOURCE_REPO="$(cd -- "${ADDONS_SOURCE_REPO}" && pwd)"
    else
        ADDONS_SOURCE_REPO="${REPO_ROOT}"
    fi

    [[ -d "${ADDONS_SOURCE_REPO}" ]] || die "Addons source repo does not exist: ${ADDONS_SOURCE_REPO}"
    ODOO_ADDONS_PATH="${ODOO_CORE_PATH}/addons,${ADDONS_TARGET_REPO}"

    if [[ -z "${DR_PRIMARY_PUBLIC_HOST:-}" && "${PUBLIC_HOSTNAME}" != "_" ]]; then
        DR_PRIMARY_PUBLIC_HOST="${PUBLIC_HOSTNAME}"
    elif [[ -z "${DR_PRIMARY_PUBLIC_HOST:-}" ]]; then
        DR_PRIMARY_PUBLIC_HOST="CHANGE_ME"
    fi
}

ensure_odoo_core() {
    if [[ -x "${ODOO_CORE_PATH}/odoo-bin" ]]; then
        log "Odoo core already present at ${ODOO_CORE_PATH}"
        return
    fi

    ensure_dir "$(dirname "${ODOO_CORE_PATH}")" 755
    log "Cloning Odoo ${ODOO_CORE_REF} into ${ODOO_CORE_PATH}"
    git clone --branch "${ODOO_CORE_REF}" --depth 1 "${ODOO_CORE_GIT_URL}" "${ODOO_CORE_PATH}"
    chown -R "${ODOO_USER}:${ODOO_GROUP}" "${ODOO_CORE_PATH}"
}

sync_addons_repo() {
    if [[ "${ADDONS_SOURCE_REPO}" == "${ADDONS_TARGET_REPO}" ]]; then
        log "Addons repo already in target location ${ADDONS_TARGET_REPO}"
        return
    fi

    ensure_dir "${ADDONS_TARGET_REPO}" 755
    log "Syncing addons repo from ${ADDONS_SOURCE_REPO} to ${ADDONS_TARGET_REPO}"
    rsync -a \
        --exclude=.git/ \
        --exclude=.venv/ \
        --exclude=__pycache__/ \
        --exclude=ops/database_dr/.env \
        --exclude=ops/ubuntu_host/.env \
        "${ADDONS_SOURCE_REPO}/" "${ADDONS_TARGET_REPO}/"
    chown -R "${ODOO_USER}:${ODOO_GROUP}" "${ADDONS_TARGET_REPO}"
}

ensure_python_environment() {
    local requirements_path="${ODOO_CORE_PATH}/requirements.txt"

    [[ -f "${requirements_path}" ]] || die "Odoo requirements file not found: ${requirements_path}"

    if [[ ! -x "${ODOO_VENV_PATH}/bin/python3" ]]; then
        log "Creating Python virtual environment at ${ODOO_VENV_PATH}"
        python3 -m venv "${ODOO_VENV_PATH}"
    fi

    log "Installing Python packages for Odoo"
    "${ODOO_VENV_PATH}/bin/pip" install --upgrade pip setuptools wheel
    "${ODOO_VENV_PATH}/bin/pip" install -r "${requirements_path}"

    chown -R "${ODOO_USER}:${ODOO_GROUP}" "${ODOO_VENV_PATH}"
}

configure_postgresql() {
    log "Ensuring PostgreSQL service is enabled"
    systemctl enable --now postgresql

    local db_user_sql db_password_sql db_name_sql db_owner_sql
    db_user_sql="$(sql_quote_literal "${ODOO_DB_USER}")"
    db_password_sql="$(sql_quote_literal "${ODOO_DB_PASSWORD}")"
    db_name_sql="$(sql_quote_literal "${ODOO_DB_NAME}")"
    db_owner_sql="$(sql_quote_literal "${ODOO_DB_USER}")"

    log "Ensuring PostgreSQL role ${ODOO_DB_USER} exists"
    runuser -u postgres -- psql postgres -v ON_ERROR_STOP=1 \
        <<SQL
DO \$do\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${db_user_sql}') THEN
        EXECUTE format('CREATE ROLE %I WITH LOGIN CREATEDB PASSWORD %L', '${db_user_sql}', '${db_password_sql}');
    ELSE
        EXECUTE format('ALTER ROLE %I WITH LOGIN CREATEDB PASSWORD %L', '${db_user_sql}', '${db_password_sql}');
        EXECUTE format('ALTER ROLE %I WITH CREATEDB', '${db_user_sql}');
    END IF;
END
\$do\$;
SQL

    if [[ "${ODOO_CREATE_APP_DATABASE:-0}" == "1" ]]; then
        log "Ensuring application database ${ODOO_DB_NAME} exists"
        runuser -u postgres -- psql postgres -v ON_ERROR_STOP=1 \
            <<SQL
DO \$do\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${db_name_sql}') THEN
        EXECUTE format('CREATE DATABASE %I OWNER %I', '${db_name_sql}', '${db_owner_sql}');
    END IF;
END
\$do\$;
SQL
    fi
}

install_odoo_conf() {
    log "Rendering Odoo config to ${ODOO_CONF_PATH}"
    render_template "${TEMPLATE_DIR}/odoo.conf.ini" "${ODOO_CONF_PATH}"
    chmod 600 "${ODOO_CONF_PATH}"
    chown "${ODOO_USER}:${ODOO_GROUP}" "${ODOO_CONF_PATH}"
}

install_odoo_service() {
    log "Installing systemd unit /etc/systemd/system/openeducat.service"
    render_template "${TEMPLATE_DIR}/openeducat.service" /etc/systemd/system/openeducat.service
    chmod 644 /etc/systemd/system/openeducat.service
    systemctl daemon-reload
    systemctl enable --now openeducat.service
}

install_nginx_site() {
    local available_path="/etc/nginx/sites-available/${NGINX_SITE_NAME}.conf"
    local enabled_path="/etc/nginx/sites-enabled/${NGINX_SITE_NAME}.conf"

    log "Installing nginx site ${available_path}"
    render_template "${TEMPLATE_DIR}/nginx.openeducat.conf" "${available_path}"
    chmod 644 "${available_path}"

    if [[ "${DISABLE_NGINX_DEFAULT_SITE:-1}" == "1" && -e /etc/nginx/sites-enabled/default ]]; then
        rm -f /etc/nginx/sites-enabled/default
    fi

    ln -sfn "${available_path}" "${enabled_path}"
    nginx -t
    systemctl enable --now nginx
    systemctl reload nginx
}

install_dr_env() {
    [[ "${INSTALL_DR_ENV:-1}" == "1" ]] || return 0

    log "Writing DR environment file to ${DR_ENV_PATH}"
    cat > "${DR_ENV_PATH}" <<EOF
# Source Odoo/PostgreSQL settings
ODOO_CONF=${ODOO_CONF_PATH}
ODOO_DATA_DIR=${ODOO_DATA_DIR}
ODOO_DATABASES="${ODOO_DB_NAME}"
ODOO_BIN=${ODOO_CORE_PATH}/odoo-bin
REPO_ROOT=${ADDONS_TARGET_REPO}
INCLUDE_REPO_ARCHIVE=1
REPO_ARCHIVE_NAME=openeducat_erp_repo.tar.gz

PGHOST=${ODOO_DB_HOST}
PGPORT=${ODOO_DB_PORT}
PGUSER=${ODOO_DB_USER}
PGPASSWORD=${ODOO_DB_PASSWORD}

# Backup settings
BACKUP_ROOT=${DR_BACKUP_ROOT}
BACKUP_SET_RETENTION=${DR_BACKUP_SET_RETENTION}
BACKUP_MAX_AGE_HOURS=${DR_BACKUP_MAX_AGE_HOURS}
RESTORE_DRILL_MAX_AGE_DAYS=${DR_RESTORE_DRILL_MAX_AGE_DAYS}
DISK_WARN_PERCENT=${DR_DISK_WARN_PERCENT}
DISK_CRIT_PERCENT=${DR_DISK_CRIT_PERCENT}

# Restore target settings
RESTORE_PGHOST=${DR_RESTORE_PGHOST}
RESTORE_PGPORT=${DR_RESTORE_PGPORT}
RESTORE_PGUSER=${DR_RESTORE_PGUSER}
RESTORE_PGPASSWORD=${DR_RESTORE_PGPASSWORD}
RESTORE_PGSSLMODE=${DR_RESTORE_PGSSLMODE}
RESTORE_ADMIN_DB=${DR_RESTORE_ADMIN_DB}
RESTORE_TARGET_DB_PREFIX=${DR_RESTORE_TARGET_DB_PREFIX}
RESTORE_TARGET_DB_SUFFIX=${DR_RESTORE_TARGET_DB_SUFFIX}
RESTORE_FILESTORE_ROOT=${DR_RESTORE_FILESTORE_ROOT}

# Stage 2 logical replication settings
PRIMARY_ADMIN_PGHOST=${ODOO_DB_HOST}
PRIMARY_ADMIN_PGPORT=${ODOO_DB_PORT}
PRIMARY_ADMIN_PGUSER=postgres
PRIMARY_ADMIN_PGPASSWORD=
PRIMARY_ADMIN_PGSSLMODE=prefer
PRIMARY_ADMIN_DB=postgres
PRIMARY_DB_OWNER=${ODOO_DB_USER}
PRIMARY_PUBLIC_HOST=${DR_PRIMARY_PUBLIC_HOST}
PRIMARY_PUBLIC_PORT=${DR_PRIMARY_PUBLIC_PORT}
PRIMARY_REPLICATION_SSLMODE=require

SUBSCRIBER_ADMIN_PGHOST=
SUBSCRIBER_ADMIN_PGPORT=
SUBSCRIBER_ADMIN_PGUSER=
SUBSCRIBER_ADMIN_PGPASSWORD=
SUBSCRIBER_ADMIN_PGSSLMODE=require
SUBSCRIBER_ADMIN_DB=postgres
SUBSCRIBER_DB_PREFIX=${DR_RESTORE_TARGET_DB_PREFIX}
SUBSCRIBER_DB_SUFFIX=${DR_RESTORE_TARGET_DB_SUFFIX}

REPLICATION_USER=${DR_REPLICATION_USER}
REPLICATION_PASSWORD=${DR_REPLICATION_PASSWORD}
PUBLICATION_PREFIX=openeducat_pub_
SUBSCRIPTION_PREFIX=openeducat_sub_
REPLICATION_SLOT_PREFIX=openeducat_slot_

REPLICATION_LAG_WARN_SECONDS=300
REPLICATION_LAG_CRIT_SECONDS=1800
REPLICATION_SLOT_LAG_WARN_BYTES=1073741824
REPLICATION_SLOT_LAG_CRIT_BYTES=5368709120

# Cloudinary runtime media settings
CLOUDINARY_ENABLED=0
CLOUDINARY_CLOUD_NAME=CHANGE_ME
CLOUDINARY_API_KEY=CHANGE_ME
CLOUDINARY_API_SECRET=CHANGE_ME
CLOUDINARY_FOLDER_PREFIX=openeducat
CLOUDINARY_ENVIRONMENT=prod
CLOUDINARY_SCHOOL_CODE=CHANGE_ME
CLOUDINARY_DELIVERY_MODE=authenticated
CLOUDINARY_MAX_UPLOAD_MB=8
CLOUDINARY_DELETE_REMOTE_ON_UNLINK=1
CLOUDINARY_DELETE_RETENTION_DAYS=15
EOF

    chown root:"${ODOO_GROUP}" "${DR_ENV_PATH}"
    chmod 640 "${DR_ENV_PATH}"
}

install_dr_units() {
    [[ "${INSTALL_DR_UNITS:-1}" == "1" ]] || return 0

    log "Installing DR systemd units"
    install -m 644 "${ADDONS_TARGET_REPO}/ops/database_dr/systemd/"*.service /etc/systemd/system/
    install -m 644 "${ADDONS_TARGET_REPO}/ops/database_dr/systemd/"*.timer /etc/systemd/system/
    systemctl daemon-reload

    if [[ "${DR_ENABLE_BACKUP_TIMER:-0}" == "1" ]]; then
        systemctl enable --now openeducat-backup.timer
    fi
    if [[ "${DR_ENABLE_BACKUP_HEALTH_TIMER:-0}" == "1" ]]; then
        systemctl enable --now openeducat-backup-health.timer
    fi
    if [[ "${DR_ENABLE_RESTORE_DRILL_TIMER:-0}" == "1" ]]; then
        systemctl enable --now openeducat-restore-drill.timer
    fi
    if [[ "${DR_ENABLE_CLOUDINARY_TIMERS:-0}" == "1" ]]; then
        systemctl enable --now openeducat-cloudinary-health.timer
        systemctl enable --now openeducat-cloudinary-inventory.timer
    fi
    if [[ "${DR_ENABLE_STAGE2_TIMERS:-0}" == "1" ]]; then
        systemctl enable --now openeducat-replication-health.timer
    fi
}

print_summary() {
    local access_hint="the server IP"

    if [[ "${PUBLIC_HOSTNAME}" != "_" ]]; then
        access_hint="http://${PUBLIC_HOSTNAME}"
    fi

    cat <<EOF

OpenEduCat host install complete.

Main paths:
  Odoo core:      ${ODOO_CORE_PATH}
  Addons repo:    ${ADDONS_TARGET_REPO}
  Odoo config:    ${ODOO_CONF_PATH}
  Odoo service:   /etc/systemd/system/openeducat.service
  Nginx site:     /etc/nginx/sites-available/${NGINX_SITE_NAME}.conf
  DR env:         ${DR_ENV_PATH}

Service checks:
  systemctl status openeducat.service --no-pager
  systemctl status nginx --no-pager

Next steps:
  1. Visit ${access_hint}.
  2. Create the first Odoo database if you left ODOO_CREATE_APP_DATABASE=0.
  3. Install the needed OpenEduCat modules from Apps.
  4. After the first database exists, run:
     sudo -u ${ODOO_USER} ENV_FILE=${DR_ENV_PATH} \\
       ${ADDONS_TARGET_REPO}/ops/database_dr/bin/run_database_dr.sh stage1 --skip-restore-drill
     Note: use the deployed repo at ${ADDONS_TARGET_REPO}, not a home-directory clone.
  5. Add TLS once DNS is pointed at the VPS.
EOF
}

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    require_root
    load_env
    require_real_vars ODOO_ADMIN_PASSWORD ODOO_DB_PASSWORD
    prepare_repo_paths
    install_base_packages
    ensure_command git
    ensure_command rsync
    ensure_command python3
    ensure_command psql
    ensure_system_user
    ensure_layout
    ensure_odoo_core
    sync_addons_repo
    ensure_python_environment
    configure_postgresql
    install_odoo_conf
    install_odoo_service
    install_nginx_site
    install_dr_env
    install_dr_units
    print_summary
}

main "$@"
