# Failover Runbook

Use this only when the local PostgreSQL primary is not recoverable within the
accepted RTO. Do not fail over for minor or quickly-fixable incidents.

## Preconditions

- Stage 1 backups are current and `check_backup_health.sh` passes, or
- Stage 2 replication is active and `check_replication_health.sh` confirms
  acceptable lag
- The matching filestore archive for the selected database state is available
- The recovery server has the same OpenEduCat/Odoo code and configuration shape
- The Aiven-side database names and credentials are confirmed
- If Cloudinary storage is enabled, `bin/check_cloudinary_health.sh` passes and
  the Cloudinary credentials are present on the recovery host

## Manual Failover

1. Stop Odoo on the local production host.
2. Capture the incident timestamp and the exact backup set or subscriber state
   you are promoting.
3. If Stage 1 is in use, restore the chosen backup set into the Aiven backup
   database with `bin/restore_backup_set.sh`.
4. Restore the matching filestore archive to the recovery server.
5. Replace the database section of `odoo.conf` with
   [odoo.aiven-failover.conf.ini](./templates/odoo.aiven-failover.conf.ini).
6. If the application server changes, update any reverse proxy, DNS, or load
   balancer configuration.
7. Start Odoo.
8. Run smoke tests:
   - login as an administrator
   - open student records
   - open admission records
   - open fees/invoice flows
   - open at least one Cloudinary-backed image
   - open at least one attachment from the restored filestore or Cloudinary
   - generate one representative report
   - if Cloudinary storage is enabled, run
     `ops/database_dr/bin/compare_cloudinary_inventory.sh`
9. Record whether the failover database came from a restored dump or the live
   logical subscriber.

## Failback

Do not point Odoo back at the old local database. It is stale by definition
once Aiven accepts writes.

Choose one of these approaches:

1. Keep Aiven as the new primary and update the normal-operation config to
   match.
2. Rebuild the local PostgreSQL server from a fresh Aiven backup, then repoint
   Odoo during a controlled maintenance window.
3. Provision a new local PostgreSQL primary from an Aiven export, then recreate
   replication in the reverse direction if you still need a standby.

## Post-Incident Checklist

- record the exact database and filestore snapshot that was used
- record the Cloudinary inventory comparison result if Cloudinary storage is enabled
- record observed data loss window if any
- record actual failover time and smoke-test results
- rotate any emergency-only credentials that were exposed during the event
- decide whether replication needs to be recreated or simply resumed
