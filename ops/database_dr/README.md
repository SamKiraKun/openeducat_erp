# OpenEduCat Database DR Operations

This directory turns the high-level design in `DBplan.md` into executable
operations artifacts for both stages of the plan.

Scope covered here:

- Stage 1 discovery, backup, restore validation, and scheduling
- Stage 2 logical replication setup helpers, verification, and health checks
- failover/failback and module-upgrade runbooks
- Odoo config templates and PostgreSQL access templates

It still does not implement dual-write or automatic multi-master failover. Odoo
should still point to one primary PostgreSQL database at a time.

## Files

- `bin/discover_odoo_env.sh`: answers the Milestone 1 discovery questions from
  `DBplan.md`
- `bin/run_database_dr.sh`: single entrypoint that orchestrates the Stage 1 and
  Stage 2 flows by calling the underlying scripts in a safe order
- `bin/backup_openeducat.sh`: creates a timestamped backup set containing
  database dumps, filestore archives, checksums, an `odoo.conf` snapshot, and
  an optional archive of the deployed addons repository
- `bin/restore_backup_set.sh`: restores one or more backup-set dumps into a
  target PostgreSQL server such as Aiven; optionally extracts filestore
  archives for a recovery drill
- `bin/run_restore_drill.sh`: restores the latest backup set using the current
  environment-file configuration
- `bin/check_backup_health.sh`: validates backup freshness, checksum integrity,
  optional restore-drill recency, and local backup-disk usage thresholds
- `bin/check_cloudinary_health.sh`: validates Cloudinary credentials and confirms
  the runtime media account is reachable
- `bin/migrate_cloudinary_attachments.sh`: migrates local Odoo attachments to
  Cloudinary, supports dry runs and reverse restores
- `bin/compare_cloudinary_inventory.sh`: compares Odoo attachment counts with
  the remote Cloudinary inventory for each configured database
- `bin/setup_logical_replication.sh`: checks prerequisites, creates replication
  users/publications on the local primary, prints subscriber SQL, or applies
  subscriptions to the Aiven-side databases
- `bin/check_replication_health.sh`: validates subscription lag and slot health
  for Stage 2
- `systemd/openeducat-backup.service`: one-shot backup unit
- `systemd/openeducat-backup.timer`: nightly schedule for the backup unit
- `systemd/openeducat-backup-health.*`: hourly backup health validation
- `systemd/openeducat-cloudinary-health.*`: hourly Cloudinary credential and
  reachability validation
- `systemd/openeducat-cloudinary-inventory.*`: daily remote-vs-database asset
  count comparison
- `systemd/openeducat-replication-health.*`: 15-minute Stage 2 health check
- `systemd/openeducat-restore-drill.*`: monthly restore drill
- `.env.example`: configuration template for all scripts
- `templates/`: Odoo and PostgreSQL config snippets for normal operation and
  failover
- `FAILOVER_RUNBOOK.md`: exact manual failover and failback steps
- `LOGICAL_REPLICATION.md`: Stage 2 workflow and commands
- `MODULE_UPGRADE_RUNBOOK.md`: replication-aware Odoo upgrade workflow

## Expected Backup Layout

Each run writes a new directory under `BACKUP_ROOT`:

```text
/var/backups/openeducat/2026-06-04_02-15-00/
  backup_manifest.env
  checksums.txt
  openeducat_prod.dump
  openeducat_prod_filestore.tar.gz
  openeducat_erp_repo.tar.gz
  odoo.conf.snapshot
```

`latest` is updated to point at the newest successful backup set.
`latest_validated` is updated after a successful restore drill.

## Stage 1 Workflow

If you prefer one command instead of running each script yourself, use:

```bash
ops/database_dr/bin/run_database_dr.sh stage1
```

That wrapper runs the same Stage 1 order below. Use
`--skip-restore-drill` only if the restore target is not ready yet, and
`--skip-cloudinary-health` only if you intentionally want to skip that check for
the current run.

1. Copy `.env.example` to `.env` or to `/etc/openeducat/backup.env`.
2. Fill in the real PostgreSQL credentials, database names, and paths.
3. Run `bin/discover_odoo_env.sh` on the production server to confirm
   `odoo.conf`, `data_dir`, filestore location, PostgreSQL version, and database
   sizes.
4. Run `bin/backup_openeducat.sh` manually and verify that a new backup set is
   created.
5. Run `bin/restore_backup_set.sh <backup_set_path>` against Aiven or a throwaway
   PostgreSQL target to prove the latest dump restores cleanly.
6. Run `bin/check_backup_health.sh` to verify freshness, checksums, and disk
   thresholds.
7. If Cloudinary-backed runtime media is enabled, run
   `bin/check_cloudinary_health.sh`.
8. Run `bin/migrate_cloudinary_attachments.sh --dry-run` and confirm the
   selected counts before the first migration batch.
9. After a migration batch, run `bin/compare_cloudinary_inventory.sh`.
10. Install the Stage 1 systemd units once the manual run is stable.

## Stage 2 Workflow

If you prefer one command per phase instead of the individual replication
scripts, use:

```bash
ops/database_dr/bin/run_database_dr.sh stage2-check
ops/database_dr/bin/run_database_dr.sh stage2-apply
ops/database_dr/bin/run_database_dr.sh stage2-verify
```

Use `stage2-print-subscriber-sql` when you want the SQL emitted instead of
having the wrapper create subscriptions directly.

1. Fill in the Stage 2 replication settings in the environment file.
2. Run `bin/setup_logical_replication.sh check-prereqs`.
3. If the prerequisite checks pass, run
   `bin/setup_logical_replication.sh apply-primary`.
4. Either print the exact subscriber SQL with
   `bin/setup_logical_replication.sh print-subscriber-sql`
   or create the subscriptions directly with
   `bin/setup_logical_replication.sh apply-subscriber`.
5. Run `bin/check_replication_health.sh`.
6. Install the Stage 2 health-check timer after replication is stable.

## Example Commands

For a local/manual checkout with `ops/database_dr/.env`, run these as the SSH
user that owns that clone and `.env` file.

```bash
cp ops/database_dr/.env.example ops/database_dr/.env
chmod 600 ops/database_dr/.env
chmod +x ops/database_dr/bin/*.sh

ops/database_dr/bin/run_database_dr.sh stage1
ops/database_dr/bin/run_database_dr.sh stage1 --skip-restore-drill
ops/database_dr/bin/run_database_dr.sh stage2-check
ops/database_dr/bin/run_database_dr.sh stage2-print-subscriber-sql
ops/database_dr/bin/run_database_dr.sh stage2-apply
ops/database_dr/bin/run_database_dr.sh stage2-verify

ops/database_dr/bin/discover_odoo_env.sh
ops/database_dr/bin/backup_openeducat.sh
ops/database_dr/bin/restore_backup_set.sh /var/backups/openeducat/latest
ops/database_dr/bin/run_restore_drill.sh
ops/database_dr/bin/check_backup_health.sh
ops/database_dr/bin/check_cloudinary_health.sh
ops/database_dr/bin/migrate_cloudinary_attachments.sh --dry-run --limit 100
ops/database_dr/bin/compare_cloudinary_inventory.sh
ops/database_dr/bin/setup_logical_replication.sh check-prereqs
ops/database_dr/bin/check_replication_health.sh
```

For an installed Ubuntu host created by `ops/ubuntu_host/install_openeducat_host.sh`,
prefer the deployed repo and installed env file:

```bash
sudo -u odoo ENV_FILE=/etc/openeducat/backup.env \
  /opt/odoo/custom-addons/openeducat_erp/ops/database_dr/bin/run_database_dr.sh discover

sudo -u odoo ENV_FILE=/etc/openeducat/backup.env \
  /opt/odoo/custom-addons/openeducat_erp/ops/database_dr/bin/run_database_dr.sh stage1 --skip-restore-drill
```

That mode is preferred on a live host because `/etc/odoo/odoo.conf` and
`/var/lib/odoo` are typically owned by `odoo`, not by the SSH user.

If you want a full Odoo recovery drill, set `RESTORE_FILESTORE_ROOT` and keep
`RESTORE_TARGET_DB_PREFIX` / `RESTORE_TARGET_DB_SUFFIX` empty so the extracted
filestore directory name matches the restored database name.

## systemd Installation

The included units expect:

- the repo to live at `/opt/odoo/custom-addons/openeducat_erp`
- the environment file to live at `/etc/openeducat/backup.env`

After adjusting those paths if needed:

```bash
sudo install -d -m 750 /etc/openeducat
sudo install -m 600 ops/database_dr/.env /etc/openeducat/backup.env
sudo install -m 644 ops/database_dr/systemd/*.service /etc/systemd/system/
sudo install -m 644 ops/database_dr/systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now openeducat-backup.timer
sudo systemctl enable --now openeducat-backup-health.timer
sudo systemctl enable --now openeducat-restore-drill.timer
sudo systemctl enable --now openeducat-cloudinary-health.timer
sudo systemctl enable --now openeducat-cloudinary-inventory.timer
# Enable this only after Stage 2 is live.
sudo systemctl enable --now openeducat-replication-health.timer
```

## Additional Runbooks

- [Logical Replication](./LOGICAL_REPLICATION.md)
- [Failover Runbook](./FAILOVER_RUNBOOK.md)
- [Module Upgrade Runbook](./MODULE_UPGRADE_RUNBOOK.md)

## What Still Needs Live Infrastructure Execution

- create and harden the Aiven PostgreSQL service
- store secrets outside Git and rotate them
- put the real Cloudinary credentials into the environment file or secret store
- choose off-server backup storage if backup sets should also be copied out of
  `BACKUP_ROOT`
- wire alerts around backup success/failure and disk growth
- run the scripts on the actual Odoo/PostgreSQL host with real credentials
- test Odoo itself against the restored or replicated databases before calling
  the deployment complete
