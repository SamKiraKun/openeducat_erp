# Module Upgrade Runbook

Odoo module upgrades can change schemas. Treat them as replication-sensitive
operations.

## Before Upgrade

1. Run `ops/database_dr/bin/check_backup_health.sh`.
2. If Stage 2 is active, run `ops/database_dr/bin/check_replication_health.sh`.
3. If Cloudinary storage is enabled, run
   `ops/database_dr/bin/check_cloudinary_health.sh`.
4. Take an on-demand backup with `ops/database_dr/bin/backup_openeducat.sh`.
5. Record:
   - backup-set path
   - Odoo version
   - deployed OpenEduCat commit
   - database list being upgraded

## During Upgrade

1. Run the Odoo module upgrade.
2. Watch PostgreSQL logs for schema or permission failures.
3. If Stage 2 is active, check `ops/database_dr/bin/check_replication_health.sh`
   after the upgrade finishes.

## After Upgrade

1. Run Odoo smoke tests on the upgraded local primary.
2. Confirm that newly created or modified records replicate to the subscriber.
3. If Cloudinary storage is enabled, run
   `ops/database_dr/bin/compare_cloudinary_inventory.sh`.
4. Run `ops/database_dr/bin/setup_logical_replication.sh verify`.
5. If replication fails after a schema change:
   - stop relying on the stale subscriber
   - take a fresh Stage 1 backup
   - restore into the Aiven-side database
   - recreate or refresh the subscription only after the restored copy is
     consistent
