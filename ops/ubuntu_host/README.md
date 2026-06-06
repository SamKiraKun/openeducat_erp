# Ubuntu Host Installer

This directory provides one server-side entrypoint that provisions the base
OpenEduCat host layout on Ubuntu:

- Odoo Community source checkout under `/opt/odoo/odoo`
- this addons repository synced to `/opt/odoo/custom-addons/openeducat_erp`
- Python virtual environment and Odoo Python dependencies
- local PostgreSQL role for Odoo
- `/etc/odoo/odoo.conf`
- `openeducat.service` systemd unit
- nginx reverse proxy site
- optional DR environment file and DR systemd units from `ops/database_dr`

## Quick Start

1. Copy the installer config and fill in at least the required secrets:

   ```bash
   cp ops/ubuntu_host/.env.example ops/ubuntu_host/.env
   nano ops/ubuntu_host/.env
   ```

2. Run the installer as root on the Ubuntu VPS:

   ```bash
   sudo ENV_FILE=$(pwd)/ops/ubuntu_host/.env bash ops/ubuntu_host/install_openeducat_host.sh
   ```

3. Point DNS to the VPS and then add TLS separately, for example with Certbot.

## Required Values

Set real values for:

- `ODOO_ADMIN_PASSWORD`
- `ODOO_DB_PASSWORD`

Set these too if you want the DR environment file to be fully ready now:

- `DR_RESTORE_PGHOST`
- `DR_RESTORE_PGUSER`
- `DR_RESTORE_PGPASSWORD`
- `DR_REPLICATION_PASSWORD`

For Stage 2 logical replication, you will also need to edit
`/etc/openeducat/backup.env` later and provide a privileged
`PRIMARY_ADMIN_PGPASSWORD` plus a real `PRIMARY_PUBLIC_HOST` if the installer
could not derive one from `PUBLIC_HOSTNAME`.

If you do not have the restore target yet, leave the DR restore values as
`CHANGE_ME`. The installer will still complete; it just will not enable any DR
timers unless you ask it to.

## Behavior Notes

- The installer does not auto-initialize an Odoo application database by
  default. Leave `ODOO_CREATE_APP_DATABASE=0` if you want to create the first
  database through the web UI using the Odoo master password.
- If you set `ODOO_CREATE_APP_DATABASE=1`, the script creates an empty
  PostgreSQL database owned by `ODOO_DB_USER`, but it does not auto-install
  OpenEduCat modules into it.
- The generated Odoo config keeps `list_db = True` by default so the first
  database can be created from the browser. After the initial setup, harden it
  by setting `ODOO_LIST_DB=False` and optionally `ODOO_DB_FILTER=^your_db_name$`.
- DR timers are installed but disabled by default. After your first real Odoo
  database exists, run:

  ```bash
  sudo -u odoo ENV_FILE=/etc/openeducat/backup.env \
    /opt/odoo/custom-addons/openeducat_erp/ops/database_dr/bin/run_database_dr.sh stage1 --skip-restore-drill
  ```

  Then enable the timers you actually want.

## Main Outputs

- Odoo config: `/etc/odoo/odoo.conf`
- Odoo service: `/etc/systemd/system/openeducat.service`
- nginx site: `/etc/nginx/sites-available/openeducat.conf`
- DR env: `/etc/openeducat/backup.env`

## Optional Follow-Up

- enable TLS with Certbot after the hostname resolves correctly
- create the first database in Odoo
- install the required OpenEduCat modules from Apps
- run `run_database_dr.sh stage1` after the first database exists
- enable the DR timers that match your rollout stage
